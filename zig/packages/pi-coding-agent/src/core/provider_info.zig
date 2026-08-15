//! Thin re-export shim. The canonical implementation lives at
//! `zig/src/ai/provider_info.zig`. Existing call sites continue to
//! `@import("provider_info.zig")` (or `@import("../core/provider_info.zig")`)
//! without modification.

const ai = @import("ai");

pub const ProviderInfo = ai.provider_info.ProviderInfo;
pub const PROVIDERS = ai.provider_info.PROVIDERS;
pub const providerInfoFor = ai.provider_info.providerInfoFor;
pub const displayNameFor = ai.provider_info.displayNameFor;
pub const defaultModelFor = ai.provider_info.defaultModelFor;
pub const missingApiKeyMessageFor = ai.provider_info.missingApiKeyMessageFor;
pub const envVarFor = ai.provider_info.envVarFor;
pub const preferInitialFor = ai.provider_info.preferInitialFor;

test {
    _ = ai.provider_info;
}
