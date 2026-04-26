//
//  AppError.swift
//  PDFViewer
//
//  Error handling and user feedback system
//

import Foundation
import SwiftUI
import Combine

// MARK: - Error Types

enum AppError: LocalizedError {
    case fileAccessDenied
    case fileNotFound
    case invalidPDF
    case corruptedPDF
    case saveFailed
    case loadFailed(String)
    case securityScopedResourceFailed
    case annotationFailed
    
    var errorDescription: String? {
        switch self {
        case .fileAccessDenied:
            return "Access Denied"
        case .fileNotFound:
            return "File Not Found"
        case .invalidPDF:
            return "Invalid PDF File"
        case .corruptedPDF:
            return "Corrupted PDF File"
        case .saveFailed:
            return "Save Failed"
        case .loadFailed(let message):
            return "Failed to Load PDF: \(message)"
        case .securityScopedResourceFailed:
            return "Security Access Failed"
        case .annotationFailed:
            return "Annotation Failed"
        }
    }
    
    var failureReason: String? {
        switch self {
        case .fileAccessDenied:
            return "You don't have permission to access this file. Please check the file permissions."
        case .fileNotFound:
            return "The file could not be found at the specified location. It may have been moved or deleted."
        case .invalidPDF:
            return "The selected file is not a valid PDF document. Please select a PDF file."
        case .corruptedPDF:
            return "The PDF file appears to be corrupted and cannot be opened."
        case .saveFailed:
            return "Unable to save the PDF file. Please check that you have write permissions."
        case .loadFailed(let message):
            return message
        case .securityScopedResourceFailed:
            return "Unable to access the file due to security restrictions. Please try opening the file again."
        case .annotationFailed:
            return "Unable to add the annotation. Please try again."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .fileAccessDenied, .securityScopedResourceFailed:
            return "Try opening the file again or check your file permissions."
        case .fileNotFound:
            return "Please verify the file location and try again."
        case .invalidPDF, .corruptedPDF:
            return "Please select a different PDF file."
        case .saveFailed:
            return "Make sure you have write access to the file location."
        case .loadFailed:
            return "Please try opening the file again."
        case .annotationFailed:
            return "Please try adding the annotation again."
        }
    }

    /// Modal errors require user acknowledgement; toast errors auto-dismiss.
    var severity: ErrorSeverity {
        switch self {
        case .fileAccessDenied, .fileNotFound, .invalidPDF, .corruptedPDF,
             .loadFailed, .securityScopedResourceFailed:
            return .modal
        case .saveFailed, .annotationFailed:
            return .toast
        }
    }
}

enum ErrorSeverity {
    case modal
    case toast
}

// MARK: - Alert Manager

class AlertManager: ObservableObject {
    @Published var alertItem: AlertItem?
    
    func showAlert(_ error: AppError) {
        alertItem = AlertItem(
            title: error.errorDescription ?? "Error",
            message: error.failureReason ?? "An unknown error occurred.",
            primaryButton: "OK",
            secondaryButton: nil
        )
    }
    
    /// Route an error to the correct feedback channel based on severity.
    func routeError(_ error: AppError, notificationManager: NotificationManager) {
        switch error.severity {
        case .modal:
            showAlert(error)
        case .toast:
            notificationManager.showError(error.failureReason ?? error.errorDescription ?? "An error occurred")
        }
    }

    func showAlert(title: String, message: String, primaryButton: String = "OK", secondaryButton: String? = nil, primaryAction: (() -> Void)? = nil, secondaryAction: (() -> Void)? = nil) {
        alertItem = AlertItem(
            title: title,
            message: message,
            primaryButton: primaryButton,
            secondaryButton: secondaryButton,
            primaryAction: primaryAction,
            secondaryAction: secondaryAction
        )
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let primaryButton: String
    let secondaryButton: String?
    var primaryAction: (() -> Void)?
    var secondaryAction: (() -> Void)?
}

struct CompactAlertView: View {
    let item: AlertItem
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text(item.message)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 10) {
                    if let secondary = item.secondaryButton {
                        Button(secondary) {
                            item.secondaryAction?()
                            onDismiss()
                        }
                        .keyboardShortcut(.cancelAction)

                        Spacer()
                    } else {
                        Spacer()
                    }

                    Button(item.primaryButton) {
                        item.primaryAction?()
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
            .frame(width: 420)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.25), radius: 18, x: 0, y: 8)
            )
        }
    }
}

// MARK: - Notification Manager

enum NotificationType {
    case success
    case error
    case info
    
    var systemImage: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
    
    var color: Color {
        switch self {
        case .success:
            return .green
        case .error:
            return .red
        case .info:
            return .blue
        }
    }
}

class NotificationManager: ObservableObject {
    @Published var notifications: [NotificationItem] = []
    
    func showNotification(_ type: NotificationType, title: String, message: String? = nil, duration: Double = AppConstants.notificationDuration) {
        let item = NotificationItem(
            type: type,
            title: title,
            message: message,
            duration: duration
        )
        notifications.append(item)
        if notifications.count > 50 {
            notifications.removeFirst(notifications.count - 50)
        }
        let id = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + item.duration) { [weak self] in
            self?.dismiss(id)
        }
    }

    func dismiss(_ id: UUID) {
        notifications.removeAll { $0.id == id }
    }
    
    func showSuccess(_ message: String) {
        showNotification(.success, title: "Success", message: message)
    }
    
    func showError(_ message: String) {
        showNotification(.error, title: "Error", message: message)
    }
    
    func showInfo(_ message: String) {
        showNotification(.info, title: "Info", message: message)
    }
}

struct NotificationItem: Identifiable {
    let id = UUID()
    let type: NotificationType
    let title: String
    let message: String?
    let duration: Double
}

// MARK: - Loading State Manager

class LoadingStateManager: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var loadingMessage: String = "Loading..."
    
    func startLoading(_ message: String = "Loading...") {
        loadingMessage = message
        isLoading = true
    }
    
    func stopLoading() {
        isLoading = false
        loadingMessage = "Loading..."
    }
}

// MARK: - Toast Notification View

struct ToastNotificationView: View {
    let item: NotificationItem
    let onDismiss: () -> Void
    @State private var isVisible = false
    @State private var dragOffset: CGFloat = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.type.systemImage)
                    .foregroundColor(item.type.color)
                    .font(.system(size: 16))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    if let message = item.message {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                
                Spacer()
                
                Button(action: {
                    dismissNotification()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(12)
        .frame(width: AppConstants.notificationWidth)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
        )
        .offset(x: dragOffset, y: isVisible ? 0 : -20)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(isVisible ? 1 : 0.95)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isVisible)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: dragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    if abs(value.translation.width) > 100 {
                        dismissNotification()
                    } else {
                        dragOffset = 0
                    }
                }
        )
        .onAppear {
            isVisible = true
        }
    }
    
    private func dismissNotification() {
        isVisible = false
        dragOffset = -AppConstants.notificationWidth
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            onDismiss()
        }
    }
}

// MARK: - Loading Overlay View

struct LoadingOverlay: View {
    let message: String
    let isLoading: Bool
    
    var body: some View {
        if isLoading {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    Text(message)
                        .foregroundColor(.white)
                        .font(.headline)
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(radius: 10)
                )
            }
        }
    }
}

