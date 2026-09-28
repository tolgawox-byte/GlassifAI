/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// WearablesViewModel.swift
//
// Registration, devices, link state, compatibility and the glasses camera
// start are now owned by one coordinator, `WearableConnectionCoordinator`
// (Runtime/WearableConnection.swift), so no two screens can keep
// contradictory connection flags. The old name remains an alias.
//

typealias WearablesViewModel = WearableConnectionCoordinator
