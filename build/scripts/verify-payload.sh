#!/bin/sh
# verify-payload.sh —— 打包前的本地验证
#
# 目的：把「装到设备上才发现」的问题挡在本地。
#
# 这个脚本是两次真机事故的产物：
#
#   事故 1（dpkg 被弄坏，Sileo 打不开）
#     postinst 用了 set -e，而里面的诊断命令 `tail 不存在的文件`、
#     `grep 没匹配` 返回非 0 → postinst 失败退出 → dpkg 把包标成半配置。
#
#   事故 2（装包时设备重启，差点掉越狱）
#     维护者脚本以 root 身份对 pidfile 里的裸 PID 执行 kill。
#     pidfile 过期 + PID 被系统回收 → 可能杀掉 SpringBoard / backboardd。
#     另外还有 nohup 在安装过程中拉起 300MB 的 node。
#
# 所以下面这些是红线（hard fail），不是建议：
#   · 维护者脚本里不许出现 set -e
#   · 不许 kill 变量（裸 PID），只许 pkill -f + 完整路径
#   · 不许 pkill -9
#   · 不许 nohup
#   · 必须以 exit 0 结束
#
# 用法：
#   sh build/scripts/verify-payload.sh              # 校验仓库里的 payload
#   sh build/scripts/verify-payload.sh <payload目录> # 校验别的目录（测试用）
#
# 退出码：0 全部通过（可能有警告）；1 有红线问题

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
PAYLOAD=${1:-"$REPO/build/payload"}

FAILS=0
WARNS=0

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; WARNS=$((WARNS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILS=$((FAILS + 1)); }
head1() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# 只匹配「代码行」：排除整行注释。
# 否则注释里提到 nohup / kill 也会被当成违规（第一次跑就误报了）。
grep_code() {
    grep -nE "$1" "$2" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true
}

if [ ! -d "$PAYLOAD" ]; then
    printf '找不到 payload 目录: %s\n' "$PAYLOAD" >&2
    exit 1
fi

printf '\033[1m=== payload 本地验证 ===\033[0m\n'
printf '目录: %s\n' "$PAYLOAD"

# ---------------------------------------------------------------- 1. 语法
head1 '1. shell 语法（sh -n）'
FOUND=0
for f in $(find "$PAYLOAD" -type f \( -name 'postinst' -o -name 'prerm' -o -name 'preinst' -o -name 'postrm' \) 2>/dev/null) \
         $(find "$PAYLOAD" -type f -path '*/bin/*' 2>/dev/null); do
    [ -f "$f" ] || continue
    # 只检查有 shebang 的
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!'*sh*) ;;
        *) continue ;;
    esac
    FOUND=$((FOUND + 1))
    if sh -n "$f" 2>/dev/null; then
        ok "$(printf '%s' "$f" | sed "s|$PAYLOAD/||")"
    else
        fail "语法错误: $(printf '%s' "$f" | sed "s|$PAYLOAD/||")"
        sh -n "$f" 2>&1 | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    fi
done
[ "$FOUND" -gt 0 ] || warn '没找到任何 shell 脚本（路径不对？）'

# ---------------------------------------------------------------- 2. 红线
head1 '2. 维护者脚本红线'

for f in $(find "$PAYLOAD" -type f \( -name 'postinst' -o -name 'prerm' -o -name 'preinst' -o -name 'postrm' \) 2>/dev/null); do
    [ -f "$f" ] || continue
    name=$(printf '%s' "$f" | sed "s|$PAYLOAD/||")

    # 检查器类脚本（preinst）自己就含这些模式字符串，允许显式豁免。
    # 豁免只跳过「模式匹配」类检查，set -e / exit 0 / shebang 照样查。
    ALLOW_PATTERNS=0
    if grep -q 'verify-allow-patterns' "$f" 2>/dev/null; then
        ALLOW_PATTERNS=1
        warn "$name: 声明了 verify-allow-patterns（跳过 kill/pkill/nohup 的模式检查）"
    fi

    # --- 2.1 set -e ---
    if [ -n "$(grep_code '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$f")" ]; then
        fail "$name: 出现了 set -e"
        printf '      事故 1 就是这么来的：任何一条诊断命令失败（tail 不存在的文件、\n'
        printf '      grep 没匹配）都会让脚本非 0 退出，dpkg 于是把包标成半配置，\n'
        printf '      Sileo 再也调不动 dpkg。改成 set -u，失败的地方自己打日志。\n'
        grep_code '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$f" | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok "$name: 没有 set -e"
    fi

    # --- 2.2 裸 PID kill ---
    if [ "$ALLOW_PATTERNS" = "0" ] && [ -n "$(grep_code 'kill[[:space:]]+(-[0-9]+[[:space:]]+)?-?"?\$' "$f" | grep -vE 'kill[[:space:]]+-0')" ]; then
        fail "$name: 对变量（裸 PID）执行 kill"
        printf '      事故 2 就是这么来的：pidfile 过期后 PID 会被系统回收，\n'
        printf '      root 身份一个 kill 就可能命中 SpringBoard/backboardd。\n'
        printf '      只用 pkill -f + 完整安装路径。\n'
        grep_code 'kill[[:space:]]+(-[0-9]+[[:space:]]+)?-?"?\$' "$f" | grep -vE 'kill[[:space:]]+-0' | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok "$name: 没有裸 PID kill"
    fi

    # --- 2.3 pkill -9 ---
    if [ "$ALLOW_PATTERNS" = "0" ] && [ -n "$(grep_code 'pkill[[:space:]]+-9' "$f")" ]; then
        fail "$name: 用了 pkill -9（SIGKILL 不给进程清理机会）"
        grep_code 'pkill[[:space:]]+-9' "$f" | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok "$name: 没有 pkill -9"
    fi

    # --- 2.4 nohup ---
    if [ "$ALLOW_PATTERNS" = "0" ] && [ -n "$(grep_code '(^|[^a-zA-Z_-])nohup([^a-zA-Z_-]|$)' "$f")" ]; then
        fail "$name: 用了 nohup（安装过程中拉起重进程）"
        printf '      iOS 上 node 冷启动要 20-60 秒、300MB+，而紧接着 uicache 还会\n'
        printf '      触发 respring。两者叠加在内存紧张的设备上很危险。\n'
        grep_code '(^|[^a-zA-Z_-])nohup([^a-zA-Z_-]|$)' "$f" | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok "$name: 没有 nohup"
    fi

    # --- 2.5 结尾 exit 0 ---
    if tail -3 "$f" 2>/dev/null | grep -qE '^[[:space:]]*exit[[:space:]]+0'; then
        ok "$name: 以 exit 0 结束"
    else
        fail "$name: 没有以 exit 0 结束（最后 3 行里找不到）"
    fi

    # --- 2.6 shebang ---
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!/bin/sh') ok "$name: shebang 是 #!/bin/sh" ;;
        '#!/bin/sh'*) ok "$name: shebang 是 #!/bin/sh" ;;
        *) fail "$name: shebang 不是 #!/bin/sh（iOS 上可能找不到解释器）" ;;
    esac
done

# --- 2.7 设备侧闸门必须在 ---
if [ -f "$PAYLOAD/DEBIAN/preinst" ]; then
    if [ -x "$PAYLOAD/DEBIAN/preinst" ]; then
        ok 'DEBIAN/preinst: 存在且可执行（设备侧会拦红线脚本）'
    else
        fail 'DEBIAN/preinst 没有执行权限，dpkg 不会运行它'
    fi
else
    fail '缺 DEBIAN/preinst —— 设备侧就没有最后一道闸了'
    printf '      preinst 在 dpkg 解包前检查即将生效的 postinst/prerm，\n'
    printf '      发现红线直接中止安装（旧版本保持不动，不会留下半配置）。\n'
fi

# ---------------------------------------------------------------- 2.8 运行期脚本
# 维护者脚本查过了，但 dsh / dsh-ctl / dsh-supervise 这些**运行期脚本**也会
# 以 root 或 mobile 身份 kill 进程，同样的误杀风险。
# dsh-supervise 就以 mobile 跑，而 SpringBoard 也是 mobile —— 误杀就是 respring。
head1 '2.8 运行期脚本：裸 PID kill'
for f in $(find "$PAYLOAD/var/jb/usr/bin" -type f 2>/dev/null); do
    [ -f "$f" ] || continue
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!'*sh*) ;;
        *) continue ;;
    esac
    name=$(basename "$f")

    # 脚本自己起的子进程（VAR=$!）允许 kill —— 那是它自己的 tail / node
    CHILD_VARS=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$!' "$f" 2>/dev/null \
                 | sed 's/^[[:space:]]*//; s/=\$!$//' | sort -u)

    BAD_KILL=0
    for var in $(grep_code 'kill[[:space:]]+(-[0-9]+[[:space:]]+)?-?"?\$' "$f" \
                 | grep -vE 'kill[[:space:]]+-0' \
                 | sed -n 's/.*"\$\([A-Za-z_][A-Za-z0-9_]*\)".*/\1/p' | sort -u); do
        if printf '%s\n' "$CHILD_VARS" | grep -qx "$var"; then
            continue   # 自己的子进程
        fi
        BAD_KILL=1
        fail "$name: 对 \$$var 执行 kill，但它不是脚本自己的子进程（\$!）"
        printf '      pidfile 里的 PID 可能是过期的，PID 回收后会指向别的进程。\n'
        printf '      改用 pkill -f + 本移植版的完整安装路径。\n'
    done
    [ "$BAD_KILL" = "0" ] && ok "$name: 没有对非子进程的裸 PID kill"
done

# ---------------------------------------------------------------- 2.9 set -u 的未定义变量
# 事故：.48 的 postinst 用了 set -u，而 $LABEL 从来没定义过。
# 脚本在 §5.3 第一行 `launchctl enable "system/$LABEL"` 就中止 ——
# bootstrap 没跑、install.log 没生成，退出码非 0，dpkg 又一次半配置。
#
# 只要脚本声明了 set -u，就必须保证每个被引用的变量都有定义。
head1 '2.9 set -u 的未定义变量'

code_lines() { grep -vE '^[[:space:]]*#' "$1" 2>/dev/null || true; }

check_unset_vars() {
    f="$1"; name="$2"
    code_lines "$f" | grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*u' || return 0

    DEFS=$(
        {
            # 普通赋值 / export 赋值
            code_lines "$f" | grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' \
                | sed 's/^[[:space:]]*//; s/^export[[:space:]]*//; s/=$//'
            # for VAR in ...
            code_lines "$f" | grep -oE 'for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in' \
                | sed 's/^for[[:space:]]*//; s/[[:space:]]*in$//'
            # 环境里本来就有 / shell 内置
            printf '%s\n' PATH HOME PWD IFS LANG LC_ALL LC_CTYPE TMPDIR USER SHELL \
                OLDPWD RANDOM LINENO OPTARG OPTIND PPID
        } 2>/dev/null | sort -u
    )

    REFS=$(
        {
            code_lines "$f" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' | tr -d '${}'
            code_lines "$f" | grep -oE '\$[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\$//'
        } 2>/dev/null | sort -u
    )

    MISSING=""
    for v in $REFS; do
        printf '%s\n' "$DEFS" | grep -qx "$v" && continue
        MISSING="$MISSING $v"
    done

    if [ -n "$MISSING" ]; then
        fail "$name: set -u 下引用了未定义变量:$MISSING"
        printf '      set -u 遇到未定义变量会立刻退出 —— 维护者脚本中途退出\n'
        printf '      就等于 dpkg 半配置。要么定义它，要么别用 set -u。\n'
    else
        ok "$name: set -u 下没有未定义变量"
    fi
}

for f in $(find "$PAYLOAD" -type f 2>/dev/null); do
    [ -f "$f" ] || continue
    case "$(head -1 "$f" 2>/dev/null)" in
        '#!'*sh*) ;;
        *) continue ;;
    esac
    check_unset_vars "$f" "$(printf '%s' "$f" | sed "s|$PAYLOAD/||")"
done

# ---------------------------------------------------------------- 3. 可能失败的命令
head1 '3. 可能失败的命令（警告，不是红线）'
for f in $(find "$PAYLOAD" -type f \( -name 'postinst' -o -name 'prerm' \) 2>/dev/null); do
    [ -f "$f" ] || continue
    name=$(printf '%s' "$f" | sed "s|$PAYLOAD/||")
    # 只看没有 || true 兜底、也不在 if/&& 里的
    hits=$(grep -nE '^[[:space:]]*(tail|grep|ls|plutil|launchctl|nc|readlink)[[:space:]]' "$f" 2>/dev/null \
           | grep -vE '\|\|[[:space:]]*true' \
           | grep -vE '&&|\|\|' \
           | grep -vE '^[0-9]+:[[:space:]]*(if|elif|while)[[:space:]]' \
           | grep -vE '\\$' || true)
    if [ -n "$hits" ]; then
        warn "$name: 这些命令失败会返回非 0，确认都有兜底"
        printf '%s\n' "$hits" | head -5 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok "$name: 没有裸露的易失败命令"
    fi
done

# ---------------------------------------------------------------- 4. plist
head1 '4. launchd plist'
PLISTS=$(find "$PAYLOAD" -type f -name '*.plist' 2>/dev/null)
if [ -z "$PLISTS" ]; then
    warn '没找到 plist'
else
    for p in $PLISTS; do
        name=$(printf '%s' "$p" | sed "s|$PAYLOAD/||")
        if command -v plutil >/dev/null 2>&1; then
            if plutil -lint "$p" >/dev/null 2>&1; then
                ok "$name: XML 合法"
            else
                fail "$name: plutil -lint 失败"
                continue
            fi
        fi
        for key in Label ProgramArguments RunAtLoad; do
            grep -q "<key>$key</key>" "$p" || fail "$name: 缺 $key"
        done
        # ProgramArguments 第一个元素必须是 payload 里真实存在的可执行文件
        # ProgramArguments 可能是「解释器 + 脚本」两段式（/bin/sh script）。
        # 解释器是系统路径，不用查 payload；脚本必须存在且可执行。
        prog=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$p" \
               | sed -n 's|.*<string>\(/var/jb/[^<]*\)</string>.*|\1|p' | head -1)
        if [ -n "$prog" ]; then
            rel=$(printf '%s' "$prog" | sed 's|^/var/jb/||')
            if [ -f "$PAYLOAD/var/jb/$rel" ]; then
                if [ -x "$PAYLOAD/var/jb/$rel" ]; then
                    ok "$name: 启动目标存在且可执行（$rel）"
                else
                    fail "$name: 启动目标没有执行权限（$rel）"
                fi
            else
                fail "$name: 启动目标不在 payload 里（$rel）"
            fi
        else
            # 没有 /var/jb 开头的参数 —— 说明用的是纯系统程序，
            # 那至少要能看出它是不是解释器 + 脚本的写法
            first=$(sed -n '/<key>ProgramArguments<\/key>/,/<\/array>/p' "$p" \
                    | sed -n 's|.*<string>\([^<]*\)</string>.*|\1|p' | head -1)
            case "$first" in
                /bin/sh|/bin/bash|/usr/bin/*)
                    fail "$name: 用了解释器 $first，但没找到要执行的脚本参数" ;;
                '')
                    fail "$name: ProgramArguments 解析不出内容" ;;
                *)
                    warn "$name: 启动目标是系统路径 $first，跳过 payload 检查" ;;
            esac
        fi
    done
fi

# ---------------------------------------------------------------- 5. control
head1 '5. DEBIAN/control'
CTRL="$PAYLOAD/DEBIAN/control"
if [ -f "$CTRL" ]; then
    for fld in Package Version Architecture Maintainer Description; do
        grep -qE "^$fld: .+" "$CTRL" || fail "control 缺字段: $fld"
    done
    # Debian control 不支持 # 注释
    if grep -qE '^#' "$CTRL"; then
        fail 'control 里有 # 注释行（Debian control 语法不支持注释）'
        grep -nE '^#' "$CTRL" | head -3 | while IFS= read -r l; do printf '      %s\n' "$l"; done
    else
        ok 'control 没有非法注释'
    fi
    ok 'control 必需字段齐全'
else
    warn '没有 DEBIAN/control（CI 里是动态生成的，正常）'
fi

# ---------------------------------------------------------------- 6. 可执行位
head1 '6. 可执行位'
for f in $(find "$PAYLOAD/var/jb/usr/bin" -type f 2>/dev/null); do
    if [ -x "$f" ]; then
        ok "$(basename "$f") 可执行"
    else
        fail "$(basename "$f") 没有执行权限（装上去会 EACCES）"
    fi
done

# ---------------------------------------------------------------- 汇总
head1 '汇总'
if [ "$FAILS" -gt 0 ]; then
    printf '\033[31m✗ %d 个红线问题，%d 个警告\033[0m\n' "$FAILS" "$WARNS"
    printf '\n红线问题会让设备出事故（dpkg 损坏 / 重启），必须修完再打包。\n'
    exit 1
fi
printf '\033[32m✓ 全部通过\033[0m（%d 个警告）\n' "$WARNS"
[ "$WARNS" -gt 0 ] && printf '警告项建议看一眼，不是阻塞项。\n'
exit 0
