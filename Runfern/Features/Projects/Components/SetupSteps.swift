import SwiftUI

/// Setup progress inside the status card: overall progress and the steps as a checklist, with
/// the reason a run stopped shown at the step that failed (Plan 2.2, NEW06).
struct SetupSteps: View {
    let environment: DevEnvironment
    let currentStep: ProvisioningStep?
    let progress: Double?
    let isRunning: Bool
    /// Why the last run stopped.
    var error: String? = nil

    private var steps: [ProvisioningStep] { ProvisioningStep.allCases }
    private var completedCount: Int { steps.filter(environment.hasCompleted).count }

    /// The first open step when the last run ended with an error.
    var failedStep: ProvisioningStep? {
        error == nil || isRunning ? nil : steps.first { !environment.hasCompleted($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress ?? Double(completedCount) / Double(steps.count))
                Text("Step \(min(completedCount + 1, steps.count)) of \(steps.count)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(steps, id: \.self) { step in
                    VStack(alignment: .leading, spacing: 2) {
                        // Centered, because the spinner has no text baseline to align with.
                        HStack(spacing: 10) {
                            icon(for: step)
                                .frame(width: 20, height: 20)
                            Text(step.title)
                                .font(.subheadline.weight(isHighlighted(step) ? .semibold : .regular))
                                .foregroundStyle(environment.hasCompleted(step) || isHighlighted(step) ? .primary : .secondary)
                        }
                        if step == failedStep, let error {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.leading, 30)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(environment.hasCompleted(step) ? String(localized: "done") : String(localized: "pending"))
                }
            }
        }
    }

    private func isHighlighted(_ step: ProvisioningStep) -> Bool {
        (step == currentStep && isRunning) || step == failedStep
    }

    @ViewBuilder
    private func icon(for step: ProvisioningStep) -> some View {
        if environment.hasCompleted(step) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        } else if step == currentStep, isRunning {
            ProgressView().controlSize(.small)
        } else if step == failedStep {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else {
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        }
    }
}
