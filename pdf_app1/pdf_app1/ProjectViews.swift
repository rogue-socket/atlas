//
//  ProjectViews.swift
//  PDFViewer
//
//  Views for project management and file display
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Project Row View
struct ProjectRowView: View {
    let project: Project
    let projectsManager: ProjectsManager
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: (Project) -> Void
    let onDelete: (Project) -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.blue)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                HStack {
                    Text("\(project.files.count) PDFs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text(project.createdAt, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Rename") {
                onRename(project)
            }
            
            Button("Delete") {
                onDelete(project)
            }
        }
    }
}

// MARK: - Create Project View
struct CreateProjectView: View {
    @Binding var projectName: String
    @Binding var pickedURLs: [URL]
    let onCreate: (String, [URL]) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var showingFilePicker = false
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Create New Project")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Project Name")
                    .font(.headline)
                
                TextField("Enter project name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PDF Files")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button("Add Files") {
                        showingFilePicker = true
                    }
                    .buttonStyle(.bordered)
                }
                
                if pickedURLs.isEmpty {
                    Text("No files selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(pickedURLs, id: \.self) { url in
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        pickedURLs.removeAll { $0 == url }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Create") {
                    onCreate(projectName, pickedURLs)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectName.isEmpty || pickedURLs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
        .sheet(isPresented: $showingFilePicker) {
            DocumentPickerView(urls: $pickedURLs)
        }
    }
}

// MARK: - Document Picker View
struct DocumentPickerView: View {
    @Binding var urls: [URL]
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Select PDF Files")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 16) {
                Button("Choose Files...") {
                    let panel = NSOpenPanel()
                    panel.title = "Select PDF Files"
                    panel.allowsMultipleSelection = true
                    panel.allowedContentTypes = [.pdf]
                    panel.begin { response in
                        if response == .OK {
                            urls.append(contentsOf: panel.urls)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                
                if !urls.isEmpty {
                    Divider()
                    
                    Text("Selected Files:")
                        .font(.headline)
                    
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(urls, id: \.self) { url in
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .foregroundColor(.blue)
                                        .font(.caption)
                                    
                                    Text(url.lastPathComponent)
                                        .font(.caption)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    
                                    Spacer()
                                    
                                    Button(action: {
                                        urls.removeAll { $0 == url }
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                        .frame(maxHeight: 200)
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400, height: 300)
    }
}

// MARK: - Rename Project View
struct RenameProjectView: View {
    let projectID: UUID
    @Binding var currentName: String
    let onRename: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Rename Project")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("New Name")
                    .font(.headline)
                
                TextField("Enter new project name", text: $currentName)
                    .textFieldStyle(.roundedBorder)
            }
            
            Spacer()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Rename") {
                    onRename(currentName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(currentName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300, height: 150)
    }
}
