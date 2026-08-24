#!/usr/bin/env bash
#
# SBQuailty - lib/ipinfo.sh
# IP 质量：地理与 ASN 信息、IP 类型、风控评分、风险因子、流媒体/AI 解锁、邮局与 DNSBL
#
# 移植自 IPQuality (xykt)：db_* / MediaUnlockTest_* / OpenAITest / check_mail / check_dnsbl
# 与原版的差别：
#   - 不打印报告、不上传 upload.check.place、不拉取展示广告
#   - 结果写入结果存储（rows/ip.<v>.*），由 lib/report.sh 统一渲染
#
# 全局变量前缀 IPQ_，函数前缀 ipq_。

IPQ_RAW_BASE="https://github.com/xykt/IPQuality/raw/main"
IPQ_RAW_MIRROR="https://testingcf.jsdelivr.net/gh/xykt/IPQuality@main"

# 浏览器 UA：多数风控接口对非浏览器 UA 返回不同结果
IPQ_UA_BROWSER="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# ===================== 文案表 =====================
declare -A IPQ_TYPE IPQ_RISK IPQ_MEDIA IPQ_LABEL

ipq_set_language() {
  if [ "${SB_LANG:-cn}" = en ]; then
    IPQ_TYPE=( [business]="Business" [isp]="ISP" [hosting]="Hosting" [education]="Education"
               [government]="Government" [banking]="Banking" [organization]="Organization"
               [military]="Military" [library]="Library" [cdn]="CDN" [lineisp]="Fixed Line ISP"
               [mobile]="Mobile ISP" [spider]="Search Spider" [reserved]="Reserved" [other]="Other" )
    IPQ_RISK=( [verylow]="Very Low" [low]="Low" [medium]="Medium" [elevated]="Elevated"
               [high]="High" [veryhigh]="Very High" [suspicious]="Suspicious" [risky]="Risky"
               [highrisk]="High Risk" [dos]="DoS Source" )
    IPQ_MEDIA=( [yes]="Unlocked" [no]="Blocked" [bad]="Failed" [org]="Originals Only"
                [pending]="Pending" [cn]="CN Region" [noprem]="No Premium" [idc]="IDC IP"
                [web]="Web Only" [app]="App Only" [nodata]="N/A" [dns]="DNS Unlock" [native]="Native" )
    IPQ_LABEL=( [asn]="ASN" [org]="Organization" [country]="Country/Region" [city]="City"
                [region]="Subdivision" [continent]="Continent" [timezone]="Timezone"
                [postal]="Postal Code" [coords]="Coordinates" [map]="Map" [regcountry]="Registered Country"
                [type]="Address Type" [consistent]="Consistent" [inconsistent]="Inconsistent"
                [proxy]="Proxy" [vpn]="VPN" [tor]="Tor Exit" [server]="Datacenter" [abuser]="Abuser"
                [robot]="Bot/Crawler" [yes]="Yes" [no]="No" [unknown]="Unknown"
                [port25]="Port 25 (outbound)" [dnsbl]="DNSBL" [mailsrv]="Reachable Mail Providers"
                [open]="Open" [blocked]="Blocked" )
  else
    IPQ_TYPE=( [business]="商业" [isp]="运营商" [hosting]="主机托管" [education]="教育"
               [government]="政府" [banking]="金融" [organization]="组织" [military]="军事"
               [library]="图书馆" [cdn]="内容分发" [lineisp]="固网运营商" [mobile]="移动运营商"
               [spider]="搜索引擎" [reserved]="保留地址" [other]="其它" )
    IPQ_RISK=( [verylow]="极低风险" [low]="低风险" [medium]="中风险" [elevated]="偏高风险"
               [high]="高风险" [veryhigh]="极高风险" [suspicious]="可疑" [risky]="风险"
               [highrisk]="高危" [dos]="攻击源" )
    IPQ_MEDIA=( [yes]="解锁" [no]="不可用" [bad]="检测失败" [org]="仅自制剧" [pending]="待解锁"
                [cn]="大陆版" [noprem]="无 Premium" [idc]="机房 IP" [web]="仅网页" [app]="仅 APP"
                [nodata]="—" [dns]="DNS 解锁" [native]="原生解锁" )
    IPQ_LABEL=( [asn]="ASN" [org]="组织" [country]="国家/地区" [city]="城市" [region]="行政区"
                [continent]="大洲" [timezone]="时区" [postal]="邮编" [coords]="经纬度" [map]="地图"
                [regcountry]="注册地" [type]="地址类型" [consistent]="原生 IP" [inconsistent]="广播 IP"
                [proxy]="代理" [vpn]="VPN" [tor]="Tor 出口" [server]="数据中心" [abuser]="滥用记录"
                [robot]="机器人/爬虫" [yes]="是" [no]="否" [unknown]="未知"
                [port25]="25 端口出站" [dnsbl]="DNSBL 黑名单" [mailsrv]="可达邮件服务商"
                [open]="开放" [blocked]="封禁" )
  fi
}

# ===================== 小工具 =====================
# 只保留 jq 可解析的响应，否则返回空串
ipq_json_or_empty() {
  local resp="$1"
  if [ -n "$resp" ] && printf '%s' "$resp" | jq . >/dev/null 2>&1; then
    printf '%s' "$resp"
  fi
}

# ipq_jq <json> <过滤表达式>  —— 取不到或为 null 时返回空串
ipq_jq() {
  local out
  out=$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)
  [ "$out" = "null" ] && out=""
  printf '%s' "$out"
}

# 布尔值归一：true/false/空
ipq_bool() {
  case "$1" in
    true|True|TRUE|1|yes)  printf 'true' ;;
    false|False|FALSE|0|no) printf 'false' ;;
    *) printf '' ;;
  esac
}

# 多个布尔值取「或」：任一 true 即 true；全部 false 才 false；否则未知
ipq_bool_any() {
  local v has_false=0
  for v in "$@"; do
    case "$(ipq_bool "$v")" in
      true)  printf 'true'; return ;;
      false) has_false=1 ;;
    esac
  done
  [ "$has_false" -eq 1 ] && printf 'false'
}

# 打码公网 IP（-f/--full-ip 时不打码）
ipq_mask_ip() {
  local ip="$1"
  [ "${SB_FULL_IP:-0}" -eq 1 ] && { printf '%s' "$ip"; return; }
  if [[ "$ip" == *:* ]]; then
    # IPv6：保留前两段
    printf '%s' "$(echo "$ip" | awk -F: '{print $1":"$2"::xxxx"}')"
  else
    printf '%s' "$(echo "$ip" | awk -F. '{print $1"."$2"."$3".xxx"}')"
  fi
}

# 经纬度转度分秒（移植自 IPQuality:generate_dms）
ipq_dms() {
  local lat="$1" lon="$2"
  [[ "$lat" =~ ^-?[0-9.]+$ ]] && [[ "$lon" =~ ^-?[0-9.]+$ ]] || return 1
  awk -v lat="$lat" -v lon="$lon" 'BEGIN {
    function dms(v, hemi,   a, d, m, s) {
      a = (v < 0) ? -v : v
      d = int(a); m = int((a - d) * 60); s = ((a - d) * 60 - m) * 60
      return sprintf("%d°%02d′%05.2f″%s", d, m, s, hemi)
    }
    printf "%s %s", dms(lat, (lat < 0 ? "S" : "N")), dms(lon, (lon < 0 ? "W" : "E"))
  }'
}

# ===================== DNS 解锁类型判定 =====================
# 移植自 IPQuality:Check_DNS_1/2/3 + Get_Unlock_Type
# 任一检测返回 0 → 判定为 DNS 解锁（存在 DNS 污染/劫持），否则为原生解锁。

ipq_calc_ip_net() {
  local ip="$1" mask="$2"
  # 不用 awk 的 and()：那是 gawk 扩展，Debian 默认的 mawk 没有。
  # 掩码只有 /8 /12 /16 /24 四种，直接按八位组截断即可。
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  case "$mask" in
    255.0.0.0)       printf '%d.0.0.0' "$a" ;;
    255.240.0.0)     printf '%d.%d.0.0' "$a" "$(( b & 240 ))" ;;
    255.255.0.0)     printf '%d.%d.0.0' "$a" "$b" ;;
    255.255.255.0)   printf '%d.%d.%d.0' "$a" "$b" "$c" ;;
    *)               printf '%s' "$ip" ;;
  esac
}

# 判断解析结果是否为公网地址（私有地址视作 DNS 劫持 -> 0）
ipq_check_dns_ip() {
  local addr="$1" server="$2"
  case "$addr" in
    *:*)
      case "${addr:0:3}" in
        fe8|FE8) echo 0; return ;;
      esac
      case "${addr:0:2}" in
        fc|FC|fd|FD|ff|FF) echo 0; return ;;
      esac
      echo 1; return ;;
    *.*.*.*)
      [ "$(ipq_calc_ip_net "$addr" 255.0.0.0)"     = "10.0.0.0" ]    && { echo 0; return; }
      [ "$(ipq_calc_ip_net "$addr" 255.240.0.0)"   = "172.16.0.0" ]  && { echo 0; return; }
      [ "$(ipq_calc_ip_net "$addr" 255.255.0.0)"   = "169.254.0.0" ] && { echo 0; return; }
      [ "$(ipq_calc_ip_net "$addr" 255.255.0.0)"   = "192.168.0.0" ] && { echo 0; return; }
      if [ -n "$server" ] && \
         [ "$(ipq_calc_ip_net "$addr" 255.255.255.0)" = "$(ipq_calc_ip_net "$server" 255.255.255.0)" ]; then
        echo 0; return
      fi
      echo 1; return ;;
    *) echo 0 ;;
  esac
}

ipq_check_dns_1() {
  sb_has nslookup || { echo 1; return; }
  local out addr server
  out=$(nslookup "$1" 2>/dev/null)
  server=$(printf '%s' "$out" | awk '/^Address:/ {print $2; exit}')
  addr=$(printf '%s' "$out" | awk '/^Name:/{f=1; next} f && /^Address:/ {print $2; exit}')
  [ -z "$addr" ] && { echo 1; return; }
  ipq_check_dns_ip "$addr" "$server"
}

ipq_check_dns_2() {
  sb_has dig || { echo 1; return; }
  local n
  n=$(dig "$1" 2>/dev/null | sed -n 's/.*ANSWER: \([0-9]*\).*/\1/p' | head -1)
  case "$n" in 0|1|2) echo 0 ;; *) echo 1 ;; esac
}

# 随机子域名应当无解析结果；有结果说明存在通配/劫持
ipq_check_dns_3() {
  sb_has dig || { echo 1; return; }
  local n
  n=$(dig "test${RANDOM}${RANDOM}.$1" 2>/dev/null | sed -n 's/.*ANSWER: \([0-9]*\).*/\1/p' | head -1)
  [ "$n" = 0 ] && echo 1 || echo 0
}

ipq_unlock_type() {
  local v
  for v in "$@"; do
    [ "$v" = 0 ] && { printf '%s' "${IPQ_MEDIA[dns]}"; return; }
  done
  printf '%s' "${IPQ_MEDIA[native]}"
}

# ===================== 数据库查询 =====================
# 每个 ipq_db_* 填充同名关联数组（IPQ_MAXMIND / IPQ_IPINFO / ...）。
# $1 = 4 或 6（协议族）

declare -A IPQ_MAXMIND IPQ_IPINFO IPQ_SCAMALYTICS IPQ_IPREGISTRY IPQ_IPAPI
declare -A IPQ_ABUSEIPDB IPQ_IP2LOCATION IPQ_DBIP IPQ_IPDATA IPQ_IPQS

ipq_map_usetype() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    business|commercial|com) printf '%s' "${IPQ_TYPE[business]}" ;;
    isp)                     printf '%s' "${IPQ_TYPE[isp]}" ;;
    hosting|dch)             printf '%s' "${IPQ_TYPE[hosting]}" ;;
    education|edu|"university/college/school") printf '%s' "${IPQ_TYPE[education]}" ;;
    government|gov)          printf '%s' "${IPQ_TYPE[government]}" ;;
    banking)                 printf '%s' "${IPQ_TYPE[banking]}" ;;
    organization|org)        printf '%s' "${IPQ_TYPE[organization]}" ;;
    military|mil)            printf '%s' "${IPQ_TYPE[military]}" ;;
    library|lib)             printf '%s' "${IPQ_TYPE[library]}" ;;
    cdn|"content delivery network") printf '%s' "${IPQ_TYPE[cdn]}" ;;
    "fixed line isp")        printf '%s' "${IPQ_TYPE[lineisp]}" ;;
    mob|"mobile isp")        printf '%s' "${IPQ_TYPE[mobile]}" ;;
    ses|"search engine spider") printf '%s' "${IPQ_TYPE[spider]}" ;;
    rsv|reserved)            printf '%s' "${IPQ_TYPE[reserved]}" ;;
    "data center/web hosting/transit") printf '%s' "${IPQ_TYPE[hosting]}" ;;
    "") printf '' ;;
    *)  printf '%s' "${IPQ_TYPE[other]}" ;;
  esac
}

ipq_db_maxmind() {
  local family="$1" resp backup
  IPQ_MAXMIND=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?lang=${SB_LANG}")")
  # 该接口是后续多个数据库的代理入口，拿不到即视为精简模式
  [ -z "$resp" ] && { IPQ_LITE=1; return 1; }
  IPQ_LITE=0

  IPQ_MAXMIND[asn]=$(ipq_jq "$resp" '.ASN.AutonomousSystemNumber')
  IPQ_MAXMIND[org]=$(ipq_jq "$resp" '.ASN.AutonomousSystemOrganization')
  IPQ_MAXMIND[city]=$(ipq_jq "$resp" '.City.Name')
  IPQ_MAXMIND[post]=$(ipq_jq "$resp" '.City.PostalCode')
  IPQ_MAXMIND[lat]=$(ipq_jq "$resp" '.City.Latitude')
  IPQ_MAXMIND[lon]=$(ipq_jq "$resp" '.City.Longitude')
  IPQ_MAXMIND[continent]=$(ipq_jq "$resp" '.City.Continent.Name')
  IPQ_MAXMIND[timezone]=$(ipq_jq "$resp" '.City.Location.TimeZone')
  IPQ_MAXMIND[sub]=$(ipq_jq "$resp" 'if .City.Subdivisions | length > 0 then .City.Subdivisions[0].Name else "" end')
  IPQ_MAXMIND[countrycode]=$(ipq_jq "$resp" '.Country.IsoCode')
  IPQ_MAXMIND[country]=$(ipq_jq "$resp" '.Country.Name')
  IPQ_MAXMIND[regcountrycode]=$(ipq_jq "$resp" '.Country.RegisteredCountry.IsoCode')
  IPQ_MAXMIND[regcountry]=$(ipq_jq "$resp" '.Country.RegisteredCountry.Name')

  # 中文接口部分字段缺失时用英文结果补齐（与原版一致）
  if [ "${SB_LANG:-cn}" != en ]; then
    local k
    backup=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?lang=en")")
    if [ -n "$backup" ]; then
      [ -z "${IPQ_MAXMIND[org]}" ]       && IPQ_MAXMIND[org]=$(ipq_jq "$backup" '.ASN.AutonomousSystemOrganization')
      [ -z "${IPQ_MAXMIND[city]}" ]      && IPQ_MAXMIND[city]=$(ipq_jq "$backup" '.City.Name')
      [ -z "${IPQ_MAXMIND[continent]}" ] && IPQ_MAXMIND[continent]=$(ipq_jq "$backup" '.City.Continent.Name')
      [ -z "${IPQ_MAXMIND[sub]}" ]       && IPQ_MAXMIND[sub]=$(ipq_jq "$backup" 'if .City.Subdivisions | length > 0 then .City.Subdivisions[0].Name else "" end')
      [ -z "${IPQ_MAXMIND[country]}" ]   && IPQ_MAXMIND[country]=$(ipq_jq "$backup" '.Country.Name')
      [ -z "${IPQ_MAXMIND[regcountry]}" ] && IPQ_MAXMIND[regcountry]=$(ipq_jq "$backup" '.Country.RegisteredCountry.Name')
    fi
  fi
  return 0
}

ipq_db_ipinfo() {
  local resp iso3166
  IPQ_IPINFO=()
  # IPv6 走默认出口：ipinfo widget 对 -6 常返回错误
  if [[ "$IPQ_IP" == *:* ]]; then
    resp=$(ipq_json_or_empty "$(curl -sL -m 10 -A "$IPQ_UA_BROWSER" "https://ipinfo.io/widget/demo/$IPQ_IP" 2>/dev/null)")
  else
    resp=$(ipq_json_or_empty "$(sb_curl "https://ipinfo.io/widget/demo/$IPQ_IP")")
  fi
  [ -z "$resp" ] && return 1

  IPQ_IPINFO[usetype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.data.asn.type')")
  IPQ_IPINFO[comtype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.data.company.type')")
  IPQ_IPINFO[asn]=$(ipq_jq "$resp" '.data.asn.asn' | sed 's/^AS//')
  IPQ_IPINFO[org]=$(ipq_jq "$resp" '.data.asn.name')
  IPQ_IPINFO[city]=$(ipq_jq "$resp" '.data.city')
  IPQ_IPINFO[post]=$(ipq_jq "$resp" '.data.postal')
  IPQ_IPINFO[timezone]=$(ipq_jq "$resp" '.data.timezone')
  IPQ_IPINFO[countrycode]=$(ipq_jq "$resp" '.data.country')
  IPQ_IPINFO[regcountrycode]=$(ipq_jq "$resp" '.data.abuse.country')
  local loc
  loc=$(ipq_jq "$resp" '.data.loc')
  IPQ_IPINFO[lat]=$(printf '%s' "$loc" | cut -d, -f1)
  IPQ_IPINFO[lon]=$(printf '%s' "$loc" | cut -d, -f2)
  IPQ_IPINFO[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.data.privacy.proxy')")
  IPQ_IPINFO[tor]=$(ipq_bool "$(ipq_jq "$resp" '.data.privacy.tor')")
  IPQ_IPINFO[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.data.privacy.vpn')")
  IPQ_IPINFO[server]=$(ipq_bool "$(ipq_jq "$resp" '.data.privacy.hosting')")

  # ISO3166 表用于把 country code 转成国家名与大洲
  iso3166=$(ipq_fetch_ref iso3166.json)
  if [ -n "$iso3166" ]; then
    IPQ_IPINFO[country]=$(printf '%s' "$iso3166" | jq --arg c "${IPQ_IPINFO[countrycode]}" -r \
      '.[] | select(.["alpha-2"] == $c) | .name' 2>/dev/null | head -1)
    IPQ_IPINFO[continent]=$(printf '%s' "$iso3166" | jq --arg c "${IPQ_IPINFO[countrycode]}" -r \
      '.[] | select(.["alpha-2"] == $c) | .region' 2>/dev/null | head -1)
    IPQ_IPINFO[regcountry]=$(printf '%s' "$iso3166" | jq --arg c "${IPQ_IPINFO[regcountrycode]}" -r \
      '.[] | select(.["alpha-2"] == $c) | .name' 2>/dev/null | head -1)
  fi
  return 0
}

ipq_db_scamalytics() {
  local family="$1" resp score
  IPQ_SCAMALYTICS=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?db=scamalytics")")
  [ -z "$resp" ] && return 1
  IPQ_SCAMALYTICS[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.external_datasources.firehol.is_proxy')")
  IPQ_SCAMALYTICS[tor]=$(ipq_bool "$(ipq_jq "$resp" '.external_datasources.x4bnet.is_tor')")
  IPQ_SCAMALYTICS[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.scamalytics.scamalytics_proxy.is_vpn')")
  IPQ_SCAMALYTICS[server]=$(ipq_bool "$(ipq_jq "$resp" '.scamalytics.scamalytics_proxy.is_datacenter')")
  IPQ_SCAMALYTICS[abuser]=$(ipq_bool "$(ipq_jq "$resp" '.scamalytics.is_blacklisted_external')")
  IPQ_SCAMALYTICS[robot]=$(ipq_bool_any \
    "$(ipq_jq "$resp" '.external_datasources.x4bnet.is_blacklisted_spambot')" \
    "$(ipq_jq "$resp" '.external_datasources.x4bnet.is_bot_operamini')" \
    "$(ipq_jq "$resp" '.external_datasources.x4bnet.is_bot_semrush')")

  score=$(ipq_jq "$resp" '.scamalytics.scamalytics_score')
  IPQ_SCAMALYTICS[score]="$score"
  if [[ "$score" =~ ^[0-9]+$ ]]; then
    if   [ "$score" -lt 20 ]; then IPQ_SCAMALYTICS[risk]="${IPQ_RISK[low]}"
    elif [ "$score" -lt 60 ]; then IPQ_SCAMALYTICS[risk]="${IPQ_RISK[medium]}"
    elif [ "$score" -lt 90 ]; then IPQ_SCAMALYTICS[risk]="${IPQ_RISK[high]}"
    else                           IPQ_SCAMALYTICS[risk]="${IPQ_RISK[veryhigh]}"
    fi
  fi
  return 0
}

ipq_db_ipregistry() {
  local family="$1" html key="sb69ksjcajfs4c" resp
  IPQ_IPREGISTRY=()
  # 站点首页内嵌公开 apiKey，取不到则用兜底 key
  html=$(sb_curl "-$family" -H "User-Agent: $IPQ_UA_BROWSER" "https://ipregistry.co")
  if [[ "$html" =~ apiKey=\"([a-zA-Z0-9]+)\" ]]; then
    key="${BASH_REMATCH[1]}"
  fi
  resp=$(ipq_json_or_empty "$(curl $SB_CURL_ARGS -sS "-$family" --compressed -m 10 \
    -H "origin: https://ipregistry.co" -H "referer: https://ipregistry.co/" \
    -H "User-Agent: $IPQ_UA_BROWSER" \
    "https://api.ipregistry.co/${IPQ_IP}?hostname=true&key=$key" 2>/dev/null)")
  [ -z "$resp" ] && return 1

  IPQ_IPREGISTRY[usetype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.connection.type')")
  IPQ_IPREGISTRY[comtype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.company.type')")
  IPQ_IPREGISTRY[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.security.is_proxy')")
  IPQ_IPREGISTRY[tor]=$(ipq_bool_any "$(ipq_jq "$resp" '.security.is_tor')" "$(ipq_jq "$resp" '.security.is_tor_exit')")
  IPQ_IPREGISTRY[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.security.is_vpn')")
  IPQ_IPREGISTRY[server]=$(ipq_bool "$(ipq_jq "$resp" '.security.is_cloud_provider')")
  IPQ_IPREGISTRY[abuser]=$(ipq_bool "$(ipq_jq "$resp" '.security.is_abuser')")
  return 0
}

ipq_db_ipapi() {
  local resp score_text score_num risk_text
  IPQ_IPAPI=()
  if [[ "$IPQ_IP" == *:* ]]; then
    resp=$(ipq_json_or_empty "$(curl -sL -m 10 -H 'origin: https://ipapi.is' "https://api.ipapi.is/?q=$IPQ_IP" 2>/dev/null)")
  else
    resp=$(ipq_json_or_empty "$(sb_curl -H 'origin: https://ipapi.is' "https://api.ipapi.is/?q=$IPQ_IP")")
  fi
  [ -z "$resp" ] && return 1

  IPQ_IPAPI[usetype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.asn.type')")
  IPQ_IPAPI[comtype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.company.type')")
  IPQ_IPAPI[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.is_proxy')")
  IPQ_IPAPI[tor]=$(ipq_bool "$(ipq_jq "$resp" '.is_tor')")
  IPQ_IPAPI[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.is_vpn')")
  IPQ_IPAPI[server]=$(ipq_bool "$(ipq_jq "$resp" '.is_datacenter')")
  IPQ_IPAPI[abuser]=$(ipq_bool "$(ipq_jq "$resp" '.is_abuser')")
  IPQ_IPAPI[robot]=$(ipq_bool "$(ipq_jq "$resp" '.is_crawler')")

  # abuser_score 形如 "0.0012 (Very Low)"
  score_text=$(ipq_jq "$resp" '.company.abuser_score')
  score_num=$(printf '%s' "$score_text" | awk '{print $1}')
  risk_text=$(printf '%s' "$score_text" | awk -F'[()]' '{print $2}')
  if [[ "$score_num" =~ ^[0-9.]+$ ]]; then
    IPQ_IPAPI[score]=$(awk -v s="$score_num" 'BEGIN {printf "%.2f%%", s * 100}')
  fi
  case "$risk_text" in
    "Very Low")  IPQ_IPAPI[risk]="${IPQ_RISK[verylow]}" ;;
    "Low")       IPQ_IPAPI[risk]="${IPQ_RISK[low]}" ;;
    "Elevated")  IPQ_IPAPI[risk]="${IPQ_RISK[elevated]}" ;;
    "High")      IPQ_IPAPI[risk]="${IPQ_RISK[high]}" ;;
    "Very High") IPQ_IPAPI[risk]="${IPQ_RISK[veryhigh]}" ;;
  esac
  return 0
}

ipq_db_abuseipdb() {
  local family="$1" resp score
  IPQ_ABUSEIPDB=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?db=abuseipdb")")
  [ -z "$resp" ] && return 1
  IPQ_ABUSEIPDB[usetype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.data.usageType')")
  score=$(ipq_jq "$resp" '.data.abuseConfidenceScore')
  IPQ_ABUSEIPDB[score]="$score"
  if [[ "$score" =~ ^[0-9]+$ ]]; then
    if   [ "$score" -lt 25 ]; then IPQ_ABUSEIPDB[risk]="${IPQ_RISK[low]}"
    elif [ "$score" -lt 75 ]; then IPQ_ABUSEIPDB[risk]="${IPQ_RISK[high]}"
    else                           IPQ_ABUSEIPDB[risk]="${IPQ_RISK[dos]}"
    fi
  fi
  return 0
}

ipq_db_ip2location() {
  local family="$1" resp score
  IPQ_IP2LOCATION=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?db=ip2location")")
  [ -z "$resp" ] && return 1
  # usage_type 形如 "DCH/ISP"，取第一段
  IPQ_IP2LOCATION[usetype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.usage_type' | cut -d/ -f1)")
  IPQ_IP2LOCATION[comtype]=$(ipq_map_usetype "$(ipq_jq "$resp" '.as_info.as_usage_type' | cut -d/ -f1)")
  IPQ_IP2LOCATION[proxy]=$(ipq_bool_any \
    "$(ipq_jq "$resp" '.is_proxy')" \
    "$(ipq_jq "$resp" '.proxy.is_public_proxy')" \
    "$(ipq_jq "$resp" '.proxy.is_web_proxy')")
  IPQ_IP2LOCATION[tor]=$(ipq_bool "$(ipq_jq "$resp" '.proxy.is_tor')")
  IPQ_IP2LOCATION[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.proxy.is_vpn')")
  IPQ_IP2LOCATION[server]=$(ipq_bool "$(ipq_jq "$resp" '.proxy.is_data_center')")
  IPQ_IP2LOCATION[abuser]=$(ipq_bool "$(ipq_jq "$resp" '.proxy.is_spammer')")
  IPQ_IP2LOCATION[robot]=$(ipq_bool_any \
    "$(ipq_jq "$resp" '.proxy.is_web_crawler')" \
    "$(ipq_jq "$resp" '.proxy.is_scanner')" \
    "$(ipq_jq "$resp" '.proxy.is_botnet')")
  score=$(ipq_jq "$resp" '.fraud_score')
  IPQ_IP2LOCATION[score]="$score"
  if [[ "$score" =~ ^[0-9]+$ ]]; then
    if   [ "$score" -lt 33 ]; then IPQ_IP2LOCATION[risk]="${IPQ_RISK[low]}"
    elif [ "$score" -lt 66 ]; then IPQ_IP2LOCATION[risk]="${IPQ_RISK[medium]}"
    else                           IPQ_IP2LOCATION[risk]="${IPQ_RISK[high]}"
    fi
  fi
  return 0
}

ipq_db_dbip() {
  local page api_key resp curl_args="$SB_CURL_ARGS"
  IPQ_DBIP=()
  # IPv6 时不套用 --interface/代理，db-ip 对此常返回 403
  [[ "$IPQ_IP" == *:* ]] && curl_args=""
  page=$(curl $curl_args -sL -m 10 -A "$IPQ_UA_BROWSER" "https://db-ip.com/api/core/" 2>/dev/null)
  api_key=$(printf '%s' "$page" | sed -n 's/.*data-api-key="\([^"]*\)".*/\1/p' | head -1)
  [ -z "$api_key" ] && return 1
  resp=$(ipq_json_or_empty "$(curl $curl_args -sL -m 10 \
    -H 'content-type: text/plain;charset=UTF-8' -H 'origin: https://db-ip.com' \
    -H 'referer: https://db-ip.com/' -A "$IPQ_UA_BROWSER" \
    --data-raw '[["11.49","EUR"],["139.90","EUR"],["699.90","EUR"]]' \
    "https://api.db-ip.com/v2/$api_key/self?convertCurrencies" 2>/dev/null)")
  [ -z "$resp" ] && return 1
  IPQ_DBIP[robot]=$(ipq_bool "$(ipq_jq "$resp" '.isCrawler')")
  IPQ_DBIP[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.isProxy')")
  case "$(ipq_jq "$resp" '.threatLevel' | tr '[:upper:]' '[:lower:]')" in
    low)    IPQ_DBIP[risk]="${IPQ_RISK[low]}";    IPQ_DBIP[score]=0 ;;
    medium) IPQ_DBIP[risk]="${IPQ_RISK[medium]}"; IPQ_DBIP[score]=50 ;;
    high)   IPQ_DBIP[risk]="${IPQ_RISK[high]}";   IPQ_DBIP[score]=100 ;;
  esac
  return 0
}

ipq_db_ipdata() {
  local family="$1" resp
  IPQ_IPDATA=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?db=ipdata")")
  [ -z "$resp" ] && return 1
  IPQ_IPDATA[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.threat.is_proxy')")
  IPQ_IPDATA[tor]=$(ipq_bool "$(ipq_jq "$resp" '.threat.is_tor')")
  IPQ_IPDATA[server]=$(ipq_bool "$(ipq_jq "$resp" '.threat.is_datacenter')")
  IPQ_IPDATA[abuser]=$(ipq_bool_any \
    "$(ipq_jq "$resp" '.threat.is_threat')" \
    "$(ipq_jq "$resp" '.threat.is_known_abuser')" \
    "$(ipq_jq "$resp" '.threat.is_known_attacker')")
  return 0
}

ipq_db_ipqs() {
  local family="$1" resp score
  IPQ_IPQS=()
  resp=$(ipq_json_or_empty "$(sb_curl "-$family" "https://ipinfo.check.place/${IPQ_IP}?db=ipqualityscore")")
  [ -z "$resp" ] && return 1
  score=$(ipq_jq "$resp" '.fraud_score')
  IPQ_IPQS[score]="$score"
  if [[ "$score" =~ ^[0-9]+$ ]]; then
    if   [ "$score" -lt 75 ]; then IPQ_IPQS[risk]="${IPQ_RISK[low]}"
    elif [ "$score" -lt 85 ]; then IPQ_IPQS[risk]="${IPQ_RISK[suspicious]}"
    elif [ "$score" -lt 90 ]; then IPQ_IPQS[risk]="${IPQ_RISK[risky]}"
    else                           IPQ_IPQS[risk]="${IPQ_RISK[highrisk]}"
    fi
  fi
  IPQ_IPQS[proxy]=$(ipq_bool "$(ipq_jq "$resp" '.proxy')")
  IPQ_IPQS[tor]=$(ipq_bool "$(ipq_jq "$resp" '.tor')")
  IPQ_IPQS[vpn]=$(ipq_bool "$(ipq_jq "$resp" '.vpn')")
  IPQ_IPQS[abuser]=$(ipq_bool "$(ipq_jq "$resp" '.recent_abuse')")
  IPQ_IPQS[robot]=$(ipq_bool "$(ipq_jq "$resp" '.bot_status')")
  return 0
}

# ===================== 上游参考文件 =====================
# 优先 GitHub，失败回退 jsDelivr 镜像；结果缓存到 $SB_TMP_DIR 避免重复拉取。
ipq_fetch_ref() {
  local name="$1" cache="$SB_TMP_DIR/ref_$name"
  if [ -s "$cache" ]; then cat "$cache"; return 0; fi
  mkdir -p "$SB_TMP_DIR"
  if sb_curl -o "$cache" "$IPQ_RAW_BASE/ref/$name" 2>/dev/null && [ -s "$cache" ]; then
    cat "$cache"; return 0
  fi
  if sb_curl -o "$cache" "$IPQ_RAW_MIRROR/ref/$name" 2>/dev/null && [ -s "$cache" ]; then
    cat "$cache"; return 0
  fi
  rm -f "$cache"
  return 1
}

# ===================== 流媒体 / AI 解锁 =====================
# 各 ipq_media_* 设置 IPQ_MEDIA_STATUS / IPQ_MEDIA_REGION / IPQ_MEDIA_TYPE

ipq_media_reset() {
  IPQ_MEDIA_STATUS="${IPQ_MEDIA[bad]}"
  IPQ_MEDIA_REGION="${IPQ_MEDIA[nodata]}"
  IPQ_MEDIA_TYPE="${IPQ_MEDIA[nodata]}"
}

ipq_media_tiktok() {
  local family="$1" unlock body region
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 tiktok.com)" "$(ipq_check_dns_3 tiktok.com)")
  body=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" "https://www.tiktok.com/" 2>/dev/null)
  [[ "$body" == *"Please wait..."* ]] && \
    body=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" "https://www.tiktok.com/explore" 2>/dev/null)
  [ -z "$body" ] && return
  region=$(printf '%s' "$body" | grep -o '"region":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$region" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="$region"; IPQ_MEDIA_TYPE="$unlock"
  else
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
  fi
}

ipq_media_netflix() {
  local family="$1" unlock r1 r2 region
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 netflix.com)" "$(ipq_check_dns_2 netflix.com)" "$(ipq_check_dns_3 netflix.com)")
  # 81280792 为全球片，70143836 为受限片；两者可用性组合区分「完整解锁 / 仅自制剧」
  r1=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" -f "https://www.netflix.com/title/81280792" 2>/dev/null)
  r2=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" -f "https://www.netflix.com/title/70143836" 2>/dev/null)
  [ -z "$r1" ] && [ -z "$r2" ] && return
  region=$(printf '%s' "$r1" | sed -n 's/.*"id":"\([^"]*\)".*"countryName":"[^"]*".*/\1/p' | head -1)
  if printf '%s' "$r1" | grep -q 'Oh no!' && printf '%s' "$r2" | grep -q 'Oh no!'; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[org]}"; IPQ_MEDIA_REGION="${region:-—}"; IPQ_MEDIA_TYPE="$unlock"
  else
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="${region:-—}"; IPQ_MEDIA_TYPE="$unlock"
  fi
}

ipq_media_disney() {
  local family="$1" unlock cookies assertion token refresh gql region supported preview
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 disneyplus.com)" "$(ipq_check_dns_3 disneyplus.com)")
  cookies=$(ipq_fetch_ref cookies.txt) || return
  local auth="Bearer ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84"

  assertion=$(ipq_json_or_empty "$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" -X POST \
    "https://disney.api.edge.bamgrid.com/devices" -H "authorization: $auth" \
    -H "content-type: application/json; charset=UTF-8" \
    -d '{"deviceFamily":"browser","applicationRuntime":"chrome","deviceProfile":"windows","attributes":{}}' 2>/dev/null)")
  [ -z "$assertion" ] && return
  assertion=$(ipq_jq "$assertion" '.assertion')
  [ -z "$assertion" ] && return

  token=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" -X POST "https://disney.api.edge.bamgrid.com/token" \
    -H "authorization: $auth" -d "$(printf '%s' "$cookies" | sed -n '1p' | sed "s/DISNEYASSERTION/$assertion/g")" 2>/dev/null)
  if printf '%s' "$token" | grep -q 'forbidden-location\|403 ERROR'; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
    return
  fi
  refresh=$(ipq_jq "$token" '.refresh_token')
  [ -z "$refresh" ] && return

  gql=$(ipq_json_or_empty "$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" -X POST \
    "https://disney.api.edge.bamgrid.com/graph/v1/device/graphql" \
    -H "authorization: ZGlzbmV5JmJyb3dzZXImMS4wLjA.Cu56AgSfBTDag5NiRA81oLHkDZfu5L3CKadnefEAY84" \
    -d "$(printf '%s' "$cookies" | sed -n '8p' | sed "s/ILOVEDISNEY/$refresh/g")" 2>/dev/null)")
  [ -z "$gql" ] && return

  region=$(ipq_jq "$gql" '.extensions.sdk.session.location.countryCode')
  supported=$(ipq_jq "$gql" '.extensions.sdk.session.inSupportedLocation')
  preview=$(sb_curl "-$family" -o /dev/null -w '%{url_effective}' "https://disneyplus.com" 2>/dev/null | grep preview)

  if [ -z "$region" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
  elif [ "$region" = JP ] || [ "$supported" = true ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="$region"; IPQ_MEDIA_TYPE="$unlock"
  elif printf '%s' "$preview" | grep -q unavailable; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
  else
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[pending]}"; IPQ_MEDIA_REGION="$region"; IPQ_MEDIA_TYPE="$unlock"
  fi
}

ipq_media_youtube() {
  local family="$1" unlock body region
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 www.youtube.com)" "$(ipq_check_dns_3 www.youtube.com)")
  body=$(sb_curl "-$family" -H "Accept-Language: en" \
    -b "YSC=BiCUU3-5Gdk; CONSENT=YES+cb.20220301-11-p0.en+FX+700; PREF=tz=Asia.Shanghai" \
    "https://www.youtube.com/premium" 2>/dev/null)
  [ -z "$body" ] && return
  if printf '%s' "$body" | grep -q 'www.google.cn'; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[cn]}"
    return
  fi
  region=$(printf '%s' "$body" | sed -n 's/.*"contentRegion":"\([^"]*\)".*/\1/p' | head -1)
  if printf '%s' "$body" | grep -q 'Premium is not available in your country'; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[noprem]}"
  elif printf '%s' "$body" | grep -q 'ad-free'; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="${region:-—}"; IPQ_MEDIA_TYPE="$unlock"
  fi
}

ipq_media_primevideo() {
  local family="$1" unlock body region
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 www.primevideo.com)" "$(ipq_check_dns_3 www.primevideo.com)")
  body=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" "https://www.primevideo.com" 2>/dev/null)
  [ -z "$body" ] && return
  region=$(printf '%s' "$body" | grep -o '"currentTerritory":"[^"]*"' | head -1 | cut -d'"' -f4)
  if [ -n "$region" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="$region"; IPQ_MEDIA_TYPE="$unlock"
  else
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
  fi
}

ipq_media_reddit() {
  local family="$1" unlock resolve_opt="" resp code html region v6
  ipq_media_reset
  unlock=$(ipq_unlock_type "$(ipq_check_dns_1 reddit.com)" "$(ipq_check_dns_2 reddit.com)")
  if [ "$family" = 6 ]; then
    # reddit 主域无 AAAA 记录，需手动解析 fastly 双栈入口
    v6=$(dig AAAA reddit.com +short 2>/dev/null | head -1)
    [ -z "$v6" ] && v6=$(dig AAAA dualstack.reddit.map.fastly.net +short 2>/dev/null | head -1)
    [ -z "$v6" ] && return
    resolve_opt="--resolve www.reddit.com:443:[$v6]"
  fi
  # shellcheck disable=SC2086
  resp=$(sb_curl "-$family" -f -A "$IPQ_UA_BROWSER" $resolve_opt --write-out '\n%{http_code}' \
    "https://www.reddit.com/svc/shreddit/reddit-chat" 2>/dev/null)
  code=$(printf '%s' "$resp" | tail -n1 | tr -d '\r')
  html=$(printf '%s' "$resp" | sed '$d')
  case "$code" in
    200)
      region=$(grep -oE 'country="[^"]+"' <<< "$html" | sed -n 's/^country="\([^"]*\)"$/\1/p' | head -1)
      IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}"; IPQ_MEDIA_REGION="${region:-—}"; IPQ_MEDIA_TYPE="$unlock" ;;
    403) IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}" ;;
  esac
}

ipq_media_chatgpt() {
  local family="$1" unlock r_api r_ios blocked_api blocked_ios country code
  ipq_media_reset
  unlock=$(ipq_unlock_type \
    "$(ipq_check_dns_1 chat.openai.com)" "$(ipq_check_dns_2 chat.openai.com)" \
    "$(ipq_check_dns_1 api.openai.com)"  "$(ipq_check_dns_3 api.openai.com)")

  r_api=$(sb_curl "-$family" -H 'authorization: Bearer null' -H 'content-type: application/json' \
    -H 'origin: https://platform.openai.com' -H 'referer: https://platform.openai.com/' \
    -A "$IPQ_UA_BROWSER" 'https://api.openai.com/compliance/cookie_requirements' 2>/dev/null)
  r_ios=$(sb_curl "-$family" -A "$IPQ_UA_BROWSER" 'https://ios.chat.openai.com/' 2>/dev/null)

  blocked_api=$(printf '%s' "$r_api" | grep unsupported_country)
  blocked_ios=$(printf '%s' "$r_ios" | grep VPN)

  # unsupported_country 也可能是限流误报，用 favicon 403 二次确认
  if [ -n "$blocked_api" ]; then
    code=$(sb_curl "-$family" -o /dev/null -w '%{http_code}' -A "$IPQ_UA_BROWSER" \
      'https://chatgpt.com/favicon.ico' 2>/dev/null)
    [ "$code" != 403 ] && blocked_api=""
  fi

  country=$(sb_curl "-$family" 'https://chat.openai.com/cdn-cgi/trace' 2>/dev/null | awk -F= '/^loc=/{print $2}')

  if [ -z "$blocked_api" ] && [ -z "$blocked_ios" ] && [ -n "$r_api$r_ios" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[yes]}";  IPQ_MEDIA_REGION="${country:-—}"; IPQ_MEDIA_TYPE="$unlock"
  elif [ -n "$blocked_api" ] && [ -n "$blocked_ios" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[no]}"
  elif [ -z "$blocked_api" ] && [ -n "$blocked_ios" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[web]}";  IPQ_MEDIA_REGION="${country:-—}"; IPQ_MEDIA_TYPE="$unlock"
  elif [ -n "$blocked_api" ] && [ -z "$blocked_ios" ]; then
    IPQ_MEDIA_STATUS="${IPQ_MEDIA[app]}";  IPQ_MEDIA_REGION="${country:-—}"; IPQ_MEDIA_TYPE="$unlock"
  fi
}

# ===================== 邮局与 DNSBL =====================
# 该 IP 是否是本机的本地地址。多 IP 主机上要用 nc -s 绑定源地址，否则测的是
# 默认路由出口而不是被检测的这个 IP；但 NAT 环境下公网 IP 并非本地地址，
# 强行绑定会直接失败，所以先判断再决定绑不绑。
ipq_ip_is_local() {
  local ip="$1"
  sb_has ip || return 1
  ip -o addr show 2>/dev/null | awk -v want="$ip" '{
    for (i = 1; i <= NF; i++) {
      if ($i == "inet" || $i == "inet6") {
        split($(i + 1), a, "/")
        if (a[1] == want) { found = 1; exit }
      }
    }
  } END { exit found ? 0 : 1 }'
}

# 25 端口出站检测：本机已监听 25 -> 无法判定；否则尝试连接外部 MTA
ipq_check_port25() {
  local ip="$1"
  if sb_has ss && ss -tano 2>/dev/null | grep -q ':25\b'; then
    printf '%s' "${IPQ_LABEL[unknown]}（本机已监听 25 端口）"
    return
  fi
  if ! sb_has nc; then
    printf '%s' "${IPQ_LABEL[unknown]}（缺少 nc）"
    return
  fi
  local resp bind=""
  ipq_ip_is_local "$ip" && bind="-s $ip"
  # shellcheck disable=SC2086
  resp=$(timeout 10 bash -c "printf 'QUIT\r\n' | nc $bind -w 8 smtp.mailgun.org 25 2>&1")
  if [[ "$resp" == *220* ]]; then
    printf '%s' "${IPQ_LABEL[open]}"
  else
    printf '%s' "${IPQ_LABEL[blocked]}"
  fi
}

# 逐个邮件服务商的 MX 做 25 端口连通性测试，返回可达的服务商列表
ipq_check_mail_providers() {
  sb_has nc && sb_has dig || { printf '%s' "${IPQ_LABEL[unknown]}（缺少 nc 或 dig）"; return; }
  local -a services=(Gmail Outlook Yahoo Apple QQ MailRU AOL GMX MailCOM 163 Sohu Sina)
  local -a reachable=()
  local svc domain mx resp i=0 total=${#services[@]} bind=""
  ipq_ip_is_local "$IPQ_IP" && bind="-s $IPQ_IP"
  for svc in "${services[@]}"; do
    i=$((i + 1))
    sb_progress "$i" "$total" "邮局连通性 $svc"
    case "$svc" in
      Gmail) domain=gmail.com ;;   Outlook) domain=outlook.com ;;
      Yahoo) domain=yahoo.com ;;   Apple) domain=me.com ;;
      MailRU) domain=mail.ru ;;    AOL) domain=aol.com ;;
      GMX) domain=gmx.com ;;       MailCOM) domain=mail.com ;;
      163) domain=163.com ;;       Sohu) domain=sohu.com ;;
      Sina) domain=sina.com ;;     QQ) domain=qq.com ;;
      *) continue ;;
    esac
    mx=$(dig +short MX "$domain" 2>/dev/null | sort -n | head -1 | awk '{print $2}')
    [ -z "$mx" ] && { blocked+=("$svc"); continue; }
    # shellcheck disable=SC2086
    resp=$(timeout 5 bash -c "printf 'QUIT\r\n' | nc $bind -w 4 '${mx%.}' 25 2>&1")
    if [[ "$resp" == *220* ]]; then reachable+=("$svc"); else blocked+=("$svc"); fi
  done
  sb_progress_done
  if [ "${#reachable[@]}" -eq 0 ]; then
    printf '0/%d' "$total"
  else
    local joined=""
    for svc in "${reachable[@]}"; do
      joined+="${joined:+, }${svc}"
    done
    printf '%d/%d（%s）' "${#reachable[@]}" "$total" "$joined"
  fi
}

# DNSBL：反查 IP 在各黑名单中的收录情况（仅 IPv4）
ipq_check_dnsbl() {
  local ip="$1" list reversed total=0 clean=0 blacklisted=0 other=0 line
  sb_has dig || { printf '%s' "${IPQ_LABEL[unknown]}（缺少 dig）"; return; }
  list=$(ipq_fetch_ref dnsbl.list) || { printf '%s' "${IPQ_LABEL[unknown]}（黑名单列表拉取失败）"; return; }
  reversed=$(printf '%s' "$ip" | awk -F. '{print $4"."$3"."$2"."$1}')

  sb_spin_msg "正在查询 DNSBL 黑名单..."
  while IFS= read -r line; do
    case "$line" in
      Clean)       clean=$((clean + 1)) ;;
      Blacklisted) blacklisted=$((blacklisted + 1)) ;;
      *)           other=$((other + 1)) ;;
    esac
    total=$((total + 1))
  done < <(printf '%s\n' "$list" | sort -u | xargs -P 50 -I {} bash -c \
    "r=\$(dig +short \"$reversed.{}\" A 2>/dev/null)
     if [ -z \"\$r\" ]; then echo Clean
     elif [[ \"\$r\" =~ ^127\.255\.255\. ]]; then echo Clean
     elif [ \"\$r\" = '127.0.0.2' ]; then echo Blacklisted
     else echo Other; fi" 2>/dev/null)
  sb_progress_done

  if [ "$blacklisted" -gt 0 ]; then
    printf '%d/%d 命中（另有 %d 项异常）' "$blacklisted" "$total" "$other"
  else
    printf '%d 个黑名单中 0 个命中' "$total"
  fi
}

# ===================== 汇总写入 =====================
# 把各库的同名风险字段合并成一行「因子 | 判定」
ipq_write_factor() {
  local v="$1" key="$2" label="$3"
  local -a yes_dbs=() no_dbs=()
  local dbname arrname val
  for dbname in IPINFO SCAMALYTICS IPREGISTRY IPAPI IP2LOCATION DBIP IPDATA IPQS; do
    arrname="IPQ_${dbname}[$key]"
    val="${!arrname:-}"
    case "$val" in
      true)  yes_dbs+=("$dbname") ;;
      false) no_dbs+=("$dbname") ;;
    esac
  done
  [ "${#yes_dbs[@]}" -eq 0 ] && [ "${#no_dbs[@]}" -eq 0 ] && return 0

  local verdict joined=""
  if [ "${#yes_dbs[@]}" -gt 0 ]; then
    # 手工拼接而不是改 IFS：${arr[*]} 只取 IFS 的第一个字符做分隔符
    for dbname in "${yes_dbs[@]}"; do
      joined+="${joined:+, }${dbname}"
    done
    verdict="${IPQ_LABEL[yes]}（${joined}）"
  else
    verdict="${IPQ_LABEL[no]}"
  fi
  sb_row_add "ip.${v}.factor" "$label" "$verdict"
}

ipq_write_info() {
  local v="$1"
  # 优先 MaxMind，缺失字段回退 IPinfo
  local asn org country ccode city sub continent tz post lat lon regc regcountry
  asn="${IPQ_MAXMIND[asn]:-${IPQ_IPINFO[asn]:-}}"
  org="${IPQ_MAXMIND[org]:-${IPQ_IPINFO[org]:-}}"
  country="${IPQ_MAXMIND[country]:-${IPQ_IPINFO[country]:-}}"
  ccode="${IPQ_MAXMIND[countrycode]:-${IPQ_IPINFO[countrycode]:-}}"
  city="${IPQ_MAXMIND[city]:-${IPQ_IPINFO[city]:-}}"
  sub="${IPQ_MAXMIND[sub]:-}"
  continent="${IPQ_MAXMIND[continent]:-${IPQ_IPINFO[continent]:-}}"
  tz="${IPQ_MAXMIND[timezone]:-${IPQ_IPINFO[timezone]:-}}"
  post="${IPQ_MAXMIND[post]:-${IPQ_IPINFO[post]:-}}"
  lat="${IPQ_MAXMIND[lat]:-${IPQ_IPINFO[lat]:-}}"
  lon="${IPQ_MAXMIND[lon]:-${IPQ_IPINFO[lon]:-}}"
  regc="${IPQ_MAXMIND[regcountrycode]:-${IPQ_IPINFO[regcountrycode]:-}}"
  regcountry="${IPQ_MAXMIND[regcountry]:-${IPQ_IPINFO[regcountry]:-}}"

  [ -n "$asn" ]       && sb_row_add "ip.${v}.info" "${IPQ_LABEL[asn]}"       "AS${asn#AS}"
  [ -n "$org" ]       && sb_row_add "ip.${v}.info" "${IPQ_LABEL[org]}"       "$org"
  [ -n "$country" ]   && sb_row_add "ip.${v}.info" "${IPQ_LABEL[country]}"   "$country${ccode:+ ($ccode)}"
  [ -n "$sub" ]       && sb_row_add "ip.${v}.info" "${IPQ_LABEL[region]}"    "$sub"
  [ -n "$city" ]      && sb_row_add "ip.${v}.info" "${IPQ_LABEL[city]}"      "$city"
  [ -n "$post" ]      && sb_row_add "ip.${v}.info" "${IPQ_LABEL[postal]}"    "$post"
  [ -n "$continent" ] && sb_row_add "ip.${v}.info" "${IPQ_LABEL[continent]}" "$continent"
  [ -n "$tz" ]        && sb_row_add "ip.${v}.info" "${IPQ_LABEL[timezone]}"  "$tz"

  local dms
  dms=$(ipq_dms "$lat" "$lon") && [ -n "$dms" ] && \
    sb_row_add "ip.${v}.info" "${IPQ_LABEL[coords]}" "$dms"

  # 注册地与实际地不一致通常意味着「广播 IP」（地理位置由 whois 注册地决定）
  if [ -n "$ccode" ] && [ -n "$regc" ]; then
    if [ "$ccode" = "$regc" ]; then
      sb_row_add "ip.${v}.info" "${IPQ_LABEL[type]}" "${IPQ_LABEL[consistent]}"
    else
      sb_row_add "ip.${v}.info" "${IPQ_LABEL[type]}" "${IPQ_LABEL[inconsistent]}（${IPQ_LABEL[regcountry]}: ${regcountry:-$regc}）"
    fi
  fi
}

ipq_write_type() {
  local v="$1" dbname arr_use arr_com use com
  for dbname in IPINFO:IPinfo IPREGISTRY:ipregistry IPAPI:ipapi ABUSEIPDB:AbuseIPDB IP2LOCATION:IP2Location; do
    arr_use="IPQ_${dbname%%:*}[usetype]"
    arr_com="IPQ_${dbname%%:*}[comtype]"
    use="${!arr_use:-}"
    com="${!arr_com:-}"
    [ -z "$use" ] && [ -z "$com" ] && continue
    sb_row_add "ip.${v}.type" "${dbname#*:}" "${use:-—}" "${com:-—}"
  done
}

ipq_write_score() {
  local v="$1" entry arr_score arr_risk score risk
  for entry in SCAMALYTICS:Scamalytics IPAPI:ipapi ABUSEIPDB:AbuseIPDB \
               IP2LOCATION:IP2Location DBIP:DB-IP IPQS:IPQS; do
    arr_score="IPQ_${entry%%:*}[score]"
    arr_risk="IPQ_${entry%%:*}[risk]"
    score="${!arr_score:-}"
    risk="${!arr_risk:-}"
    [ -z "$score" ] && [ -z "$risk" ] && continue
    sb_row_add "ip.${v}.score" "${entry#*:}" "${score:-—}" "${risk:-—}"
  done
}

# ===================== 单个 IP 的完整检测 =====================
# ipq_check_one <IP> <4|6>
ipq_check_one() {
  IPQ_IP="$1"
  local family="$2" v="v${family}" step=0
  # 步数 = 数据库数 + 7 项解锁检测（快速档 5 个库，全量档 10 个）
  local total=17
  [ "${SB_PROFILE:-quick}" = all ] || total=12

  sb_kv_set "ip.${v}.display" "$(ipq_mask_ip "$IPQ_IP")"
  sb_kv_set "ip.${v}.raw" "$IPQ_IP"

  # ---- 数据库 ----
  step=$((step+1)); sb_progress "$step" "$total" "查询 MaxMind"
  ipq_db_maxmind "$family"
  step=$((step+1)); sb_progress "$step" "$total" "查询 IPinfo"
  ipq_db_ipinfo
  step=$((step+1)); sb_progress "$step" "$total" "查询 ipregistry"
  ipq_db_ipregistry "$family"
  step=$((step+1)); sb_progress "$step" "$total" "查询 ipapi"
  ipq_db_ipapi
  step=$((step+1)); sb_progress "$step" "$total" "查询 DB-IP"
  ipq_db_dbip

  # 全量档才跑收费/限流较重的库（与原版 lite 模式一致）
  if [ "${SB_PROFILE:-quick}" = all ]; then
    step=$((step+1)); sb_progress "$step" "$total" "查询 Scamalytics"
    ipq_db_scamalytics "$family"
    step=$((step+1)); sb_progress "$step" "$total" "查询 AbuseIPDB"
    ipq_db_abuseipdb "$family"
    step=$((step+1)); sb_progress "$step" "$total" "查询 IP2Location"
    ipq_db_ip2location "$family"
    step=$((step+1)); sb_progress "$step" "$total" "查询 ipdata"
    ipq_db_ipdata "$family"
    step=$((step+1)); sb_progress "$step" "$total" "查询 IPQS"
    ipq_db_ipqs "$family"
  else
    IPQ_SCAMALYTICS=(); IPQ_ABUSEIPDB=(); IPQ_IP2LOCATION=(); IPQ_IPDATA=(); IPQ_IPQS=()
  fi

  ipq_write_info  "$v"
  ipq_write_type  "$v"
  ipq_write_score "$v"
  ipq_write_factor "$v" proxy  "${IPQ_LABEL[proxy]}"
  ipq_write_factor "$v" vpn    "${IPQ_LABEL[vpn]}"
  ipq_write_factor "$v" tor    "${IPQ_LABEL[tor]}"
  ipq_write_factor "$v" server "${IPQ_LABEL[server]}"
  ipq_write_factor "$v" abuser "${IPQ_LABEL[abuser]}"
  ipq_write_factor "$v" robot  "${IPQ_LABEL[robot]}"

  # ---- 流媒体 / AI ----
  local m result
  for m in "TikTok:ipq_media_tiktok" "Netflix:ipq_media_netflix" "Disney+:ipq_media_disney" \
           "YouTube:ipq_media_youtube" "Prime Video:ipq_media_primevideo" \
           "Reddit:ipq_media_reddit" "ChatGPT:ipq_media_chatgpt"; do
    step=$((step+1)); sb_progress "$step" "$total" "解锁检测 ${m%%:*}"
    "${m#*:}" "$family"
    # 只有真的判定出解锁方式才拼接；失败时 TYPE 是占位符「—」，拼上去会变成
    # 「检测失败 / —」这种没有信息量的字符串
    result="$IPQ_MEDIA_STATUS"
    if [ -n "$IPQ_MEDIA_TYPE" ] && [ "$IPQ_MEDIA_TYPE" != "${IPQ_MEDIA[nodata]}" ]; then
      result="$IPQ_MEDIA_STATUS / $IPQ_MEDIA_TYPE"
    fi
    sb_row_add "ip.${v}.media" "${m%%:*}" "$result" "$IPQ_MEDIA_REGION"
  done
  sb_progress_done

  # ---- 邮局与黑名单（仅 IPv4，且全量档才跑）----
  if [ "$family" = 4 ]; then
    sb_row_add "ip.${v}.mail" "${IPQ_LABEL[port25]}" "$(ipq_check_port25 "$IPQ_IP")"
    if [ "${SB_PROFILE:-quick}" = all ]; then
      sb_row_add "ip.${v}.mail" "${IPQ_LABEL[mailsrv]}" "$(ipq_check_mail_providers)"
      sb_row_add "ip.${v}.mail" "${IPQ_LABEL[dnsbl]}"   "$(ipq_check_dnsbl "$IPQ_IP")"
    fi
  fi
}

# ===================== 入口 =====================
ipq_run() {
  if ! sb_require jq; then
    sb_skip "ip" "缺少 jq，无法解析各 IP 数据库响应"
    return 0
  fi
  if ! sb_has curl; then
    sb_skip "ip" "缺少 curl"
    return 0
  fi
  if [ "${SB_IPV4_OK:-0}" -eq 0 ] && [ "${SB_IPV6_OK:-0}" -eq 0 ]; then
    sb_skip "ip" "无网络连接"
    return 0
  fi

  ipq_set_language
  # nslookup/dig 用于解锁类型判定，缺失时降级为「无法判定原生/DNS 解锁」
  sb_require dig >/dev/null 2>&1

  if [ "${SB_IPV4_OK:-0}" -eq 1 ] && [ -n "${SB_PUBLIC_IPV4:-}" ]; then
    sb_info "正在检测 IPv4 质量：$(ipq_mask_ip "$SB_PUBLIC_IPV4")"
    ipq_check_one "$SB_PUBLIC_IPV4" 4
  fi
  if [ "${SB_IPV6_OK:-0}" -eq 1 ] && [ -n "${SB_PUBLIC_IPV6:-}" ]; then
    sb_info "正在检测 IPv6 质量：$(ipq_mask_ip "$SB_PUBLIC_IPV6")"
    ipq_check_one "$SB_PUBLIC_IPV6" 6
  fi

  if sb_table_exists ip.v4.info || sb_table_exists ip.v6.info; then
    sb_status_set ip ok ""
    sb_ok "IP 质量检测完成"
  else
    sb_skip "ip" "所有 IP 数据库均无响应"
  fi
}
