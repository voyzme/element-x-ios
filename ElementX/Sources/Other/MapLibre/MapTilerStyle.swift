//
// Copyright 2023, 2024 New Vector Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only
// Please see LICENSE in the repository root for full details.
//

/// The style for a map.
/// Values should be Map Libre style IDs generated with an account where the API key belongs to.
/// For more information read [FORKING.md](https://github.com/element-hq/element-x-ios/blob/develop/docs/FORKING.md#setup-the-location-sharing).
enum MapTilerStyle: String {
    case light = "0196cf7f-10fa-7a04-8d88-a026cba04683"
    case dark = "0196d824-fd1f-74e1-8392-2698cacdeaa0"
}
