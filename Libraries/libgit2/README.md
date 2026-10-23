# libgit2

Dynamic arm64 build of libgit2 1.9.0 for macOS, linked read-only by
`GitRepo` (log walks and per-commit tree diffs).

## 已知风险(2026-10-23 全库审查 F05)

当前版本 **1.9.0** 落在官方安全公告
[GHSA-27m5-gxxh-x79j](https://github.com/libgit2/libgit2/security/advisories/GHSA-27m5-gxxh-x79j)
的受影响范围内(< 1.9.5):攻击者提供的**本地 pack 文件**可在读取路径上触发
内存耗尽。本应用不执行 fetch,但 `GitRepo.log` / `GitRepo.diffTree` 会读取
仓库内已有的 pack,因此“不发网络请求”不能排除该公告;一个恶意或损坏的
仓库可能让扫描进程 OOM。

当前 arm64 dylib SHA-256:

```
e3e7e4b05f5890ccbfada922f7e545fac886bc9465a4df08a1c58882e179914c  lib/libgit2.1.9.dylib
```

## 升级验收清单(替换二进制前逐项确认)

1. **版本**:解包后 `git_libgit2_version` 报告 ≥ 1.9.5;`include/git2/version.h`
   与 dylib 实际版本一致(审查发现过头文件与二进制漂移的可能,两者都要核)。
2. **来源与配方**:记录源码 tarball URL / commit、cmake 主要开关
   (`BUILD_SHARED_LIBS`、`USE_SSH`、`USE_HTTPS`、`REGEX_BACKEND`、
   `USE_BUNDLED_ZLIB` 等)与构建命令,写入本文件,保证可复现。
3. **架构与部署目标**:arm64,macOS 部署目标与 Package.swift 一致;
   `otool -l` 核对 `LC_ID_DYLIB` install name 与旧 dylib 相同
   (`@rpath/libgit2.1.9.dylib` 形态),否则链接脚本需同步调整。
4. **校验值**:记录新 dylib 的 SHA-256 于本文件。
5. **冒烟验证**:`GitCommitFactsTests` 全绿;对一个含 packfile 的真实仓库
   执行 `GitRepo.log` + `diffTree` 读取正常。
6. **回归关注点**:升级后首跑留意 `AppHealthMonitor` 的 `Git.scan.*`
   错误上报与 `git_commit_scan` 游标是否正常推进。
