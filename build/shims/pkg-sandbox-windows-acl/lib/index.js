// iOS shim —— 顶替 @deepseek-ai/dsh-sandbox-windows-acl
//
// 同 win32-process：sandbox-local 顶层静态 import 它，缺包会导致
// sandbox 服务整个起不来，进而 bash-sandbox / permission 全部 pending。
//
// iOS 没有 Windows ACL，这些调用点都在 win32 分支里，不会执行。

function notOnIOS(name) {
  throw new Error(`${name} 只在 Windows 上可用（iOS 移植版不应调用）`);
}

export class AclWriteGrant {
  static create() { notOnIOS('AclWriteGrant.create'); }
  add() { notOnIOS('AclWriteGrant#add'); }
  dispose() {}
}

// 这个在 win32 分支里用来判断「临时目录是否落在工作区内」。
// iOS 上永远返回 false：没有 ACL 继承问题。
export const isTempRootInsideWorkspace = () => false;
export const registerAclDiagnosisSkill = () => {};
export const tempWriteSid = () => 'S-1-0-0';
export const workspaceWriteSid = () => 'S-1-0-0';

export default {
  AclWriteGrant,
  isTempRootInsideWorkspace,
  registerAclDiagnosisSkill,
  tempWriteSid,
  workspaceWriteSid,
};
