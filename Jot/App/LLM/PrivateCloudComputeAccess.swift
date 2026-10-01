import Foundation

/// Whether this build may send requests to Apple's Private Cloud Compute.
///
/// Apple gates Private Cloud Compute behind a **managed entitlement** the
/// developer account has to be granted (App Store Small Business Program,
/// under two million first-time downloads; request it at
/// https://developer.apple.com/private-cloud-compute/). Until that
/// entitlement is granted and added to `Resources/Jot.entitlements`, iOS 27
/// still reports `PrivateCloudComputeLanguageModel().availability == .available`
/// on an eligible device — but every request fails (`ModelManagerError 1046`),
/// so the framework's own availability can't be the gate. Flip this to `true`
/// in the same change that adds the entitlement; until then Ask stays hidden
/// (features.md §14.1) and rewrites never fall back to the cloud (§7.2).
enum PrivateCloudComputeAccess {
    static let isEntitled = false
}
