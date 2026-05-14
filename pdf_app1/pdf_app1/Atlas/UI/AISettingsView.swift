//
//  AISettingsView.swift
//  Atlas
//
//  Settings panel for AI backend configuration
//

import SwiftUI
import os.log

private let log = AtlasLogger.ai

struct AISettingsView: View {
    @Bindable var serviceManager: AIServiceManager

    @State private var apiKeyInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var ollamaBaseURL: String = "http://localhost:11434"
    @State private var testStatus: TestStatus = .idle

    enum TestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            // Backend Selection
            Section("AI Backend") {
                Picker("Provider", selection: $serviceManager.selectedBackendType) {
                    ForEach(AIBackendType.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .onChange(of: serviceManager.selectedBackendType) { _, newValue in
                    serviceManager.selectedModel = newValue.availableModels.first ?? ""
                    loadAPIKey(for: newValue)
                    serviceManager.savePreferences()
                    testStatus = .idle
                }

                Picker("Model", selection: $serviceManager.selectedModel) {
                    ForEach(serviceManager.selectedBackendType.availableModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .onChange(of: serviceManager.selectedModel) { _, _ in
                    serviceManager.savePreferences()
                    testStatus = .idle
                }
            }

            // API Key
            if serviceManager.selectedBackendType.requiresAPIKey {
                Section("API Key") {
                    HStack {
                        if showAPIKey {
                            TextField("Enter API key", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("Enter API key", text: $apiKeyInput)
                                .textFieldStyle(.roundedBorder)
                        }

                        Button(action: { showAPIKey.toggle() }) {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack {
                        Button("Save Key") {
                            serviceManager.setAPIKey(apiKeyInput, for: serviceManager.selectedBackendType)
                            testStatus = .idle
                        }
                        .disabled(apiKeyInput.isEmpty)

                        if serviceManager.isConfigured {
                            Label("Configured", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }
            }

            // Ollama-specific settings
            if serviceManager.selectedBackendType == .ollama {
                Section("Ollama Configuration") {
                    TextField("Base URL", text: $ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            UserDefaults.standard.set(ollamaBaseURL, forKey: AppConstants.ollamaBaseURLKey)
                        }

                    Text("Make sure Ollama is running locally with the selected model pulled.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Test Connection
            Section("Test Connection") {
                HStack {
                    Button(action: { runTest() }) {
                        Label("Test API Connection", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(testStatus == .testing || !serviceManager.isConfigured)

                    Spacer()

                    switch testStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    case .success(let msg):
                        Label(msg, systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                    case .failure(let msg):
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                            .lineLimit(3)
                    }
                }

                if case .failure(let msg) = testStatus {
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }

            // Status
            Section("Status") {
                LabeledContent("Backend") {
                    Text(serviceManager.selectedBackendType.displayName)
                }
                LabeledContent("Model") {
                    Text(serviceManager.selectedModel)
                }
                LabeledContent("Status") {
                    Text(serviceManager.isConfigured ? "Ready" : "Not configured")
                        .foregroundColor(serviceManager.isConfigured ? .green : .orange)
                }
                LabeledContent("Tokens Used") {
                    Text("\(serviceManager.totalTokensUsed)")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 450)
        .onAppear {
            loadAPIKey(for: serviceManager.selectedBackendType)
            ollamaBaseURL = UserDefaults.standard.string(forKey: AppConstants.ollamaBaseURLKey) ?? "http://localhost:11434"
        }
    }

    private func loadAPIKey(for backend: AIBackendType) {
        apiKeyInput = serviceManager.getAPIKey(for: backend) ?? ""
    }

    private func runTest() {
        guard let backend = serviceManager.createBackend() else {
            testStatus = .failure("Could not create backend — check API key")
            return
        }

        testStatus = .testing
        log.info("[Test] Starting API test with \(backend.displayName) / \(backend.modelIdentifier)")

        Task {
            do {
                let startTime = Date()
                let response = try await backend.summarizeConcept(
                    "machine learning",
                    sourceText: "Machine learning is a subfield of artificial intelligence."
                )
                let elapsed = Date().timeIntervalSince(startTime)
                let elapsedStr = String(format: "%.1fs", elapsed)

                log.info("[Test] SUCCESS in \(elapsedStr): \(response.prefix(100))")
                testStatus = .success("OK (\(elapsedStr)) — \(response.prefix(60))...")
            } catch let error as AIError {
                log.error("[Test] FAILED: \(error.localizedDescription ?? "unknown")")
                testStatus = .failure(error.localizedDescription ?? "Unknown AI error")
            } catch {
                log.error("[Test] FAILED: \(error.localizedDescription)")
                testStatus = .failure(error.localizedDescription)
            }
        }
    }
}
