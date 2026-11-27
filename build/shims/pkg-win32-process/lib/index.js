// iOS shim —— 顶替 @deepseek-ai/dsh-win32-process
//
// 为什么需要它：
//   dsh 的 subprocess-local / runner 是**顶层静态 import** 这个包的
//   （import { loadWin32ProcessBindings } from "...win32-process"）。
//   包不存在时整个 ESM 模块加载失败 → subprocess 服务起不来 →
//   bash-sandbox / permission / ptc-runtime / terminal-controller 全部 pending，
//   结果是「bash 工具完全不可用」。
//
//   mac 的 app.asar 里只有 darwin 平台的包，win32 包根本不存在，
//   所以移植版必须自己补一个。iOS 上这些函数永远不会被调用（调用点都在
//   process.platform === "win32" 分支里），这里只需要「名字存在」。
//
// 故意抛错而不是静默返回：万一真被调到，报错信息能直接指出问题。

export class Win32Error extends Error {
  constructor(message) {
    super(message);
    this.name = 'Win32Error';
  }
}

function notOnIOS(name) {
  return () => {
    throw new Win32Error(`${name} 只在 Windows 上可用（iOS 移植版不应调用）`);
  };
}

export const loadWin32ProcessBindings = notOnIOS('loadWin32ProcessBindings');
export const probeCurrentTokenJobSupport = () => ({ supported: false });
export const closeHandleChecked = notOnIOS('closeHandleChecked');
export const isJobEmpty = notOnIOS('isJobEmpty');
export const pollProcessExit = notOnIOS('pollProcessExit');
export const spawnCurrentTokenJobProcess = notOnIOS('spawnCurrentTokenJobProcess');
export const terminateJob = notOnIOS('terminateJob');

export default {
  Win32Error,
  loadWin32ProcessBindings,
  probeCurrentTokenJobSupport,
};
