// iOS shim —— 顶替 @deepseek-ai/dsh-pwsh-local
//
// terminal-bash 顶层静态 import 它（ENCODING_PREAMBLE / resolvePwshPath），
// 缺包会让 bash 终端插件加载失败。iOS 上不跑 PowerShell。

export const ENCODING_PREAMBLE = '';

export const resolvePwshPath = () => {
  throw new Error('PowerShell 只在 Windows 上可用（iOS 移植版不应调用）');
};

export default { ENCODING_PREAMBLE, resolvePwshPath };
