import FlowBatchCore
import SwiftUI

/// Double slider that drives live preview updates smoothly and commits ONE undo step on drag completion.
struct CoalescedDoubleSlider: View {
    @Bindable var store: WorkflowStore
    let nodeID: UUID
    let key: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let actionName: String

    var body: some View {
        let current = store.document.nodes.first(where: { $0.id == nodeID })?.parameters[key]?.doubleValue ?? defaultValue
        Slider(
            value: Binding(
                get: { current },
                set: { next in
                    store.beginContinuousEdit()
                    store.setParameterTransient(nodeID: nodeID, key: key, value: .double(next))
                }
            ),
            in: range,
            onEditingChanged: { editing in
                if editing {
                    store.beginContinuousEdit()
                } else {
                    store.commitContinuousEdit(actionName: actionName)
                }
            }
        )
        .controlSize(.small)
    }
}

/// Integer slider that coalesces drag scrubbing into a single undo entry.
struct CoalescedIntSlider: View {
    @Bindable var store: WorkflowStore
    let nodeID: UUID
    let key: String
    let range: ClosedRange<Int>
    let defaultValue: Int
    let actionName: String

    var body: some View {
        let current = store.document.nodes.first(where: { $0.id == nodeID })?.parameters[key]?.intValue ?? defaultValue
        Slider(
            value: Binding(
                get: { Double(current) },
                set: { next in
                    store.beginContinuousEdit()
                    store.setParameterTransient(nodeID: nodeID, key: key, value: .int(Int(next.rounded())))
                }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1,
            onEditingChanged: { editing in
                if editing {
                    store.beginContinuousEdit()
                } else {
                    store.commitContinuousEdit(actionName: actionName)
                }
            }
        )
        .controlSize(.small)
    }
}
