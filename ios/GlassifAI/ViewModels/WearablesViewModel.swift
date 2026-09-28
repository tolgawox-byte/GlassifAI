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
// Primary view model for the GlassifAI app that manages DAT SDK integration.
// Demonstrates how to listen to device availability changes using the DAT SDK's
// device stream functionality and handle permission requests.
//

import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

@MainActor
class WearablesViewModel: ObservableObject {
  @Published var devices: [DeviceIdentifier]
  @Published var hasMockDevice: Bool
  @Published var registrationState: RegistrationState
  @Published var showGettingStartedSheet: Bool = false
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  /// Whether the glasses report a connected link to this iPhone (DAT
  /// `LinkState`); nil until a device is known. Used to arm hands-free
  /// listening only from real SDK events.
  @Published var glassesLinkConnected: Bool?
  /// Whether the glasses are worn with the hinges open (DAT 1.0
  /// `DeviceState.donState` / `hingeState`); nil while unknown.
  @Published var glassesWorn: Bool?

  private var registrationTask: Task<Void, Never>?
  private var deviceStreamTask: Task<Void, Never>?
  private var setupDeviceStreamTask: Task<Void, Never>?
  private let wearables: WearablesInterface
  private var compatibilityListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var linkStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var deviceStateListenerTokens: [DeviceIdentifier: AnyListenerToken] = [:]

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.devices = wearables.devices
    self.hasMockDevice = false
    self.registrationState = wearables.registrationState

    // Set up device stream immediately to handle MockDevice events
    setupDeviceStreamTask = Task {
      await setupDeviceStream()
    }

    registrationTask = Task {
      for await registrationState in wearables.registrationStateStream() {
        let previousState = self.registrationState
        self.registrationState = registrationState
        if self.showGettingStartedSheet == false && registrationState == .registered && previousState == .registering {
          self.showGettingStartedSheet = true
        }
      }
    }
  }

  deinit {
    registrationTask?.cancel()
    deviceStreamTask?.cancel()
    setupDeviceStreamTask?.cancel()
  }

  private func setupDeviceStream() async {
    if let task = deviceStreamTask, !task.isCancelled {
      task.cancel()
    }

    deviceStreamTask = Task {
      for await devices in wearables.devicesStream() {
        self.devices = devices
        #if canImport(MWDATMockDevice)
        self.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
        #endif
        // Monitor compatibility for each device
        monitorDeviceCompatibility(devices: devices)
      }
    }
  }

  private func monitorDeviceCompatibility(devices: [DeviceIdentifier]) {
    // Remove listeners for devices that are no longer present
    let deviceSet = Set(devices)
    compatibilityListenerTokens = compatibilityListenerTokens.filter { deviceSet.contains($0.key) }
    linkStateListenerTokens = linkStateListenerTokens.filter { deviceSet.contains($0.key) }
    deviceStateListenerTokens = deviceStateListenerTokens.filter { deviceSet.contains($0.key) }
    if devices.isEmpty {
      glassesLinkConnected = nil
      glassesWorn = nil
    }

    // Add listeners for new devices
    for deviceId in devices {
      guard compatibilityListenerTokens[deviceId] == nil else { continue }
      guard let device = wearables.deviceForIdentifier(deviceId) else { continue }

      // Capture device name before the closure to avoid Sendable issues
      let deviceName = device.nameOrId()
      let token = device.addCompatibilityListener { [weak self] compatibility in
        guard let self else { return }
        if compatibility == .deviceUpdateRequired {
          Task { @MainActor in
            self.showError("Device '\(deviceName)' requires an update to work with this app")
          }
        }
      }
      compatibilityListenerTokens[deviceId] = token

      if linkStateListenerTokens[deviceId] == nil {
        if deviceId == devices.first {
          glassesLinkConnected = device.linkState == .connected
        }
        let isPrimary = deviceId == devices.first
        linkStateListenerTokens[deviceId] = device.addLinkStateListener { [weak self] state in
          guard isPrimary else { return }
          Task { @MainActor in
            self?.glassesLinkConnected = state == .connected
          }
        }
      }

      if deviceStateListenerTokens[deviceId] == nil {
        let isPrimary = deviceId == devices.first
        // Delivered at once and on every change (DAT 1.0).
        deviceStateListenerTokens[deviceId] = device.addDeviceStateListener { [weak self] state in
          guard isPrimary else { return }
          let worn: Bool?
          switch state.donState {
          case .donned: worn = state.hingeState != .closed
          case .doffed: worn = false
          case .unknown: worn = state.hingeState == .closed ? false : nil
          }
          Task { @MainActor in
            self?.glassesWorn = worn
          }
        }
      }
    }
  }

  func connectGlasses() {
    guard registrationState != .registering else { return }
    Task { @MainActor in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func disconnectGlasses() {
    Task { @MainActor in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        showError(error.description)
      } catch {
        showError(error.localizedDescription)
      }
    }
  }

  func showError(_ error: String) {
    errorMessage = error
    showError = true
  }

  func dismissError() {
    showError = false
  }
}
