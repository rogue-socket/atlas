//
//  MergeProposalView.swift
//  Atlas
//
//  UI for reviewing and accepting/rejecting concept merge proposals
//

import SwiftUI

struct MergeProposalView: View {
    let proposals: [MergeProposal]
    var graph: KnowledgeGraph
    let mergeEngine: GraphMergeEngine
    var onDismiss: () -> Void

    @State private var processedIDs: Set<UUID> = []

    var pendingProposals: [MergeProposal] {
        proposals.filter { !processedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Merge Proposals")
                    .font(.headline)
                Spacer()
                Text("\(pendingProposals.count) remaining")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Dismiss") { onDismiss() }
                    .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Bulk action for high-confidence proposals
            if pendingProposals.contains(where: { $0.similarity > 0.9 }) {
                HStack {
                    Spacer()
                    Button("Accept All High-Confidence") {
                        for proposal in pendingProposals where proposal.similarity > 0.9 {
                            mergeEngine.executeMerge(
                                sourceNodeID: proposal.sourceNode.id,
                                targetNodeID: proposal.targetNode.id,
                                in: graph
                            )
                            processedIDs.insert(proposal.id)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            if pendingProposals.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    Text("All proposals reviewed")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(pendingProposals) { proposal in
                            MergeProposalRow(
                                proposal: proposal,
                                onAccept: {
                                    mergeEngine.executeMerge(
                                        sourceNodeID: proposal.sourceNode.id,
                                        targetNodeID: proposal.targetNode.id,
                                        in: graph
                                    )
                                    processedIDs.insert(proposal.id)
                                },
                                onReject: {
                                    processedIDs.insert(proposal.id)
                                }
                            )
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MergeProposalRow: View {
    let proposal: MergeProposal
    let onAccept: () -> Void
    let onReject: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    nodeLabel(proposal.sourceNode)
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    nodeLabel(proposal.targetNode)
                }

                HStack(spacing: 6) {
                    mergeTypeBadge(proposal.mergeType)
                    Text("Confidence: \(Int(proposal.similarity * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let llmReason = proposal.llmReason {
                    Text(llmReason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Text(proposal.reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Merge") { onAccept() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                Button("Skip") { onReject() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func nodeLabel(_ node: ConceptNode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: node.type.icon)
                .font(.caption)
                .foregroundColor(node.type.color)
            Text(node.label)
                .font(.callout)
                .lineLimit(1)
        }
    }

    private func mergeTypeBadge(_ type: MergeType) -> some View {
        let (text, color): (String, Color) = switch type {
        case .exactMatch: ("Exact", .green)
        case .semanticEquivalent: ("Semantic", .blue)
        case .partialOverlap: ("Partial", .orange)
        }
        return Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
