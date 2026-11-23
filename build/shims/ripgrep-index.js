/**
 * dsh-ios: ripgrep 解析补丁
 *
 * 问题：@vscode/ripgrep 的 lib/index.js 用
 *   require.resolve(`@vscode/ripgrep-${process.platform}-${arch}/bin/rg`)
 * 解析二进制。iOS 上 platform=ios，永远找不到 `@vscode/ripgrep-ios-arm64`，
 * 于是首次搜索调用抛 SEARCH_FAILED（glob/grep 工具全废）。
 *
 * 解法：按优先级解析
 *   1. $DSH_RG_PATH（显式覆盖）
 *   2. /var/jb/usr/bin/rg（Procursus 的 ripgrep 包）
 *   3. /usr/bin/rg, /usr/local/bin/rg
 *   4. PATH 里的 rg
 *   5. 原始 @vscode/ripgrep（桌面端照旧）
 *
 * 应用方式：构建期直接替换 @vscode/ripgrep/lib/index.js。
 * 运行时零依赖，只用 Node 内置模块。
 */
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { join, delimiter } from 'node:path';

const require = createRequire(import.meta.url);

/** 在 PATH 里找可执行的 rg。 */
function findInPath(name) {
    const dirs = (process.env.PATH ?? '').split(delimiter).filter(Boolean);
    for (const dir of dirs) {
        const candidate = join(dir, name);
        try {
            if (existsSync(candidate)) return candidate;
        } catch {
            // 忽略权限错误
        }
    }
    return undefined;
}

/** 按优先级解析 rg 路径。 */
function resolveRg() {
    // 1. 显式覆盖
    const override = process.env.DSH_RG_PATH;
    if (override && existsSync(override)) return override;

    // 2. iOS rootless 常见位置
    for (const p of ['/var/jb/usr/bin/rg', '/var/jb/bin/rg']) {
        if (existsSync(p)) return p;
    }

    // 3. 标准位置
    for (const p of ['/usr/bin/rg', '/usr/local/bin/rg', '/opt/homebrew/bin/rg']) {
        if (existsSync(p)) return p;
    }

    // 4. PATH
    const inPath = findInPath('rg');
    if (inPath) return inPath;

    // 5. 原始 npm 包（桌面端）
    const arch = process.env.npm_config_arch || process.arch;
    const binaryName = process.platform === 'win32' ? 'rg.exe' : 'rg';
    const platformPkg = `@vscode/ripgrep-${process.platform}-${arch}`;
    try {
        return require.resolve(`${platformPkg}/bin/${binaryName}`);
    } catch {
        throw new Error(
            `ripgrep 未找到。已尝试：$DSH_RG_PATH、/var/jb/usr/bin/rg、/usr/bin/rg、PATH。` +
            `请安装 Procursus 的 ripgrep 包，或设置 DSH_RG_PATH 指向 rg 二进制。`
        );
    }
}

export const rgPath = resolveRg();
