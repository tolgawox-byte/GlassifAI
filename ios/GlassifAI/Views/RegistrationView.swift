/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// RegistrationView.swift
//
// Meta AI's registration and permission callbacks used to be handled here,
// inside the glasses screen. A cold launch by the callback happened while
// sign-in was still restoring, when this view did not exist yet, and the
// callback was lost. They are now handled at the app's root
// (`GlassifAIApp` → `WearableConnectionCoordinator.handleOpenURL`). This
// view is kept only so older layouts compile; it does nothing.
//

import SwiftUI

struct RegistrationView: View {
  var body: some View {
    EmptyView()
  }
}
