# macOS 27 compatibility: research references

The native-touch and graphics additions build on the upstream project's existing
framework extraction and virtualization work. The references below document the
specific sources consulted for this compatibility investigation; they are not
claims that those projects implement or validate this adapter.

## Paravirtualized GPU protocol

[steelbrain/reims-vgpu](https://github.com/steelbrain/reims-vgpu) was the principal
public implementation reference for Apple's paravirtualized GPU wire protocol.
The investigation used commit
[`1fe0acb68b287db36f1e6c7b9f45383940b8a76f`](https://github.com/steelbrain/reims-vgpu/tree/1fe0acb68b287db36f1e6c7b9f45383940b8a76f),
particularly:

- [APV feature/version tables](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/guest/abi/features.rs)
  for negotiation boundaries.
- [Texture descriptor decoding](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/deserializer/texture_descriptor.rs)
  for the packed descriptor2 layout and usage bits.
- [FIFO execution/resource lists](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/fifo/commands/exec.rs)
  and [task commands](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/fifo/commands/task.rs)
  for resource flags, object/placement metadata and InfoIndirect semantics.
- [Segment decoding](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/deserializer.rs)
  and [local information queries](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/crates/reims-vgpu-core/src/tasks/local/info.rs)
  for segment dispatch and CPU query completion.

These protocol references were cross-checked against the target ARM guest's
AppleParavirtGPU user-space and kernel drivers and the older host runtime.
The adapter uses local C/Objective-C decoders and hooks into the existing Apple
backend; it does not embed reims-vgpu's Rust backend. The research records identify
format/semantic references rather than a port of its Rust implementation.
reims-vgpu's own code is dual-licensed
[GPL-2.0-or-later OR LGPL-3.0-or-later](https://github.com/steelbrain/reims-vgpu/blob/1fe0acb68b287db36f1e6c7b9f45383940b8a76f/LICENSE);
this citation does not relicense that code under this repository's license.

## Related work and controls

- [nfzerox/VirtualIntelMacOnAppleSilicon](https://github.com/nfzerox/VirtualIntelMacOnAppleSilicon):
  MetalSerializer/PVG compatibility context, including the distinction between
  Intel and ARM guest wire protocols. The Intel path was not transplanted into
  this ARM adapter.
- [insidegui/VirtualBuddy](https://github.com/insidegui/VirtualBuddy): Apple's
  supported Mac virtualization API usage, and the Mac-side control environment
  for comparing negotiated capabilities and shader behavior. The control result
  is not validation of the separately assembled iPad runtime.
- [HvDecompile / Worth Doing Badly](https://worthdoingbadly.com/hv/): prior
  Hypervisor.framework decompilation and iOS kernel/hypervisor research already
  credited by upstream. This is virtualization groundwork, separate from the
  PVG protocol reference above; this adapter adds no iPadOS kernel patch.
- [blacktop/ipsw](https://github.com/blacktop/ipsw): firmware/shared-cache analysis
  tooling, also credited by upstream.

The display UUID and direct-touch binding conclusions came from target-runtime
and guest-driver analysis plus physical-input tests. The ImageBlocks capability,
Info query and compute-encoder changes were checked on the specific target
runtime. Neither finding should be attributed to a third-party project's device
support claims.
