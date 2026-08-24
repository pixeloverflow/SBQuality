/*
 * SBQuailty — 连接级 TCP_INFO 采集（LD_PRELOAD）
 *
 * 搬运自 TcpQuality:tcpquality-tcpinfo.c（ibsgss），仅把符号前缀 tcpquality_
 * 改为 sbquality_、环境变量前缀改为 SBQUALITY_，逻辑未改动。
 *
 * 原理：拦截 connect()/close()，对连到目标 IP:443 的 socket 打标记；在 close()
 * （以及进程退出时）读取该 socket 的 TCP_INFO，把重传计数写到指定文件。
 * 这样拿到的是「本次测速这条连接」的重传，而不是全机统计。
 *
 * 环境变量：
 *   SBQUALITY_TCP_INFO_TARGET  目标 IP（IPv4 或 IPv6 字面量）
 *   SBQUALITY_TCP_INFO_FILE    快照输出文件
 *
 * 编译：gcc -O2 -fPIC -shared -o libsbquality-tcpinfo.so sbquality-tcpinfo.c -ldl -pthread
 */

#define _GNU_SOURCE

#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/tcp.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef TCP_INFO
#define TCP_INFO 11
#endif

#define SBQUALITY_MAX_TRACKED 32

typedef int (*sbquality_connect_fn)(int, const struct sockaddr *, socklen_t);
typedef int (*sbquality_close_fn)(int);

struct sbquality_tracked_socket {
  int fd;
  int active;
};

static sbquality_connect_fn sbquality_real_connect;
static sbquality_close_fn sbquality_real_close;
static pthread_mutex_t sbquality_lock = PTHREAD_MUTEX_INITIALIZER;
static struct sbquality_tracked_socket sbquality_sockets[SBQUALITY_MAX_TRACKED];
static char sbquality_target[INET6_ADDRSTRLEN];
static int sbquality_target_family;
static const char *sbquality_output;

static void sbquality_resolve_symbols(void) {
  if (sbquality_real_connect == NULL) {
    sbquality_real_connect = (sbquality_connect_fn)dlsym(RTLD_NEXT, "connect");
  }
  if (sbquality_real_close == NULL) {
    sbquality_real_close = (sbquality_close_fn)dlsym(RTLD_NEXT, "close");
  }
}

static void sbquality_init_config(void) {
  const char *target = getenv("SBQUALITY_TCP_INFO_TARGET");
  const char *output = getenv("SBQUALITY_TCP_INFO_FILE");
  struct in_addr target4;
  struct in6_addr target6;

  sbquality_resolve_symbols();
  sbquality_output = output;
  sbquality_target_family = 0;
  sbquality_target[0] = '\0';
  if (target == NULL || output == NULL || *target == '\0' || *output == '\0') {
    return;
  }
  if (inet_pton(AF_INET, target, &target4) == 1) {
    sbquality_target_family = AF_INET;
  } else if (inet_pton(AF_INET6, target, &target6) == 1) {
    sbquality_target_family = AF_INET6;
  } else {
    return;
  }
  strncpy(sbquality_target, target, sizeof(sbquality_target) - 1);
  sbquality_target[sizeof(sbquality_target) - 1] = '\0';
}

__attribute__((constructor)) static void sbquality_constructor(void) {
  sbquality_init_config();
}

static int sbquality_is_target(const struct sockaddr *address, socklen_t address_len) {
  char address_text[INET6_ADDRSTRLEN];
  const void *address_bytes;
  int family;
  uint16_t port;

  if (address == NULL || sbquality_target_family == 0 ||
      address_len < sizeof(sa_family_t)) {
    return 0;
  }
  family = address->sa_family;
  if (family == AF_INET && address_len >= sizeof(struct sockaddr_in) &&
      sbquality_target_family == AF_INET) {
    const struct sockaddr_in *address4 = (const struct sockaddr_in *)address;
    address_bytes = &address4->sin_addr;
    port = ntohs(address4->sin_port);
  } else if (family == AF_INET6 && address_len >= sizeof(struct sockaddr_in6) &&
             sbquality_target_family == AF_INET6) {
    const struct sockaddr_in6 *address6 = (const struct sockaddr_in6 *)address;
    address_bytes = &address6->sin6_addr;
    port = ntohs(address6->sin6_port);
  } else {
    return 0;
  }
  if (port != 443 || inet_ntop(family, address_bytes, address_text, sizeof(address_text)) == NULL) {
    return 0;
  }
  return strcmp(address_text, sbquality_target) == 0;
}

static void sbquality_mark_socket(int fd) {
  int free_slot = -1;
  int index;

  pthread_mutex_lock(&sbquality_lock);
  for (index = 0; index < SBQUALITY_MAX_TRACKED; index++) {
    if (sbquality_sockets[index].active && sbquality_sockets[index].fd == fd) {
      pthread_mutex_unlock(&sbquality_lock);
      return;
    }
    if (!sbquality_sockets[index].active && free_slot < 0) {
      free_slot = index;
    }
  }
  if (free_slot >= 0) {
    sbquality_sockets[free_slot].fd = fd;
    sbquality_sockets[free_slot].active = 1;
  }
  pthread_mutex_unlock(&sbquality_lock);
}

static int sbquality_unmark_socket(int fd) {
  int found = 0;
  int index;

  pthread_mutex_lock(&sbquality_lock);
  for (index = 0; index < SBQUALITY_MAX_TRACKED; index++) {
    if (sbquality_sockets[index].active && sbquality_sockets[index].fd == fd) {
      sbquality_sockets[index].active = 0;
      found = 1;
      break;
    }
  }
  pthread_mutex_unlock(&sbquality_lock);
  return found;
}

static void sbquality_write_snapshot(int fd) {
  struct tcp_info info;
  socklen_t info_length = sizeof(info);
  char line[256];
  int line_length;
  int output_fd;

  if (sbquality_output == NULL || *sbquality_output == '\0' ||
      getsockopt(fd, IPPROTO_TCP, TCP_INFO, &info, &info_length) != 0) {
    return;
  }
  line_length = snprintf(line, sizeof(line), "%u|%u|%u|%llu\n",
                         (unsigned int)info.tcpi_total_retrans,
                         (unsigned int)info.tcpi_data_segs_out,
                         (unsigned int)info.tcpi_segs_out,
                         (unsigned long long)info.tcpi_bytes_retrans);
  if (line_length <= 0 || (size_t)line_length >= sizeof(line)) {
    return;
  }
  /* 直接走 syscall：close() 已被本库劫持，用 libc 包装会递归 */
  output_fd = (int)syscall(SYS_openat, AT_FDCWD, sbquality_output,
                           O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
  if (output_fd < 0) {
    return;
  }
  (void)syscall(SYS_write, output_fd, line, (size_t)line_length);
  (void)syscall(SYS_close, output_fd);
}

int connect(int fd, const struct sockaddr *address, socklen_t address_len) {
  int result;
  int saved_errno;

  sbquality_resolve_symbols();
  if (sbquality_real_connect == NULL) {
    errno = ENOSYS;
    return -1;
  }
  result = sbquality_real_connect(fd, address, address_len);
  saved_errno = errno;
  if (sbquality_is_target(address, address_len) &&
      (result == 0 || saved_errno == EINPROGRESS || saved_errno == EALREADY ||
       saved_errno == EISCONN)) {
    sbquality_mark_socket(fd);
  }
  errno = saved_errno;
  return result;
}

int close(int fd) {
  int tracked;

  sbquality_resolve_symbols();
  tracked = sbquality_unmark_socket(fd);
  if (tracked) {
    sbquality_write_snapshot(fd);
  }
  if (sbquality_real_close == NULL) {
    errno = ENOSYS;
    return -1;
  }
  return sbquality_real_close(fd);
}

/* 进程被 kill 前没走 close() 的连接，在这里补一次快照 */
__attribute__((destructor)) static void sbquality_destructor(void) {
  int descriptors[SBQUALITY_MAX_TRACKED];
  int count = 0;
  int index;

  pthread_mutex_lock(&sbquality_lock);
  for (index = 0; index < SBQUALITY_MAX_TRACKED; index++) {
    if (sbquality_sockets[index].active) {
      descriptors[count++] = sbquality_sockets[index].fd;
      sbquality_sockets[index].active = 0;
    }
  }
  pthread_mutex_unlock(&sbquality_lock);
  for (index = 0; index < count; index++) {
    sbquality_write_snapshot(descriptors[index]);
  }
}
