import MailVerdictKit
import SwiftUI

/// The order actions as menu items -- one rendering for the detail's Options menu and a list
/// row's long-press menu, both fed by `OrderActionSet`.
struct OrderActionMenuItems: View {
    let flags: OrderFlags
    let onSelect: (OrderAction) -> Void

    var body: some View {
        ForEach(OrderActionSet.entries(for: flags)) { entry in
            if entry.separatorBefore {
                Divider()
            }
            Button(role: entry.isDestructive ? .destructive : nil) {
                onSelect(entry.action)
            } label: {
                Label {
                    Text(entry.title)
                    if let hint = entry.hint {
                        Text(hint)
                    }
                } icon: {
                    Image(systemName: entry.systemImage)
                }
            }
        }
    }
}

extension View {
    /// Deleting an order is irreversible, so every entry point asks first.
    func deleteOrderAlert(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        alert("Delete this order?", isPresented: isPresented) {
            Button("Delete", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its mails stay where they are.")
        }
    }

    /// The same alert for an order picked from a list: the confirm action receives the order it
    /// was raised for, so clearing the selection as the alert dismisses cannot lose it.
    func deleteOrderAlert(
        order: Binding<OrderListItem?>, onConfirm: @escaping (OrderListItem) -> Void
    ) -> some View {
        alert(
            "Delete this order?",
            isPresented: Binding(get: { order.wrappedValue != nil }, set: { if !$0 { order.wrappedValue = nil } }),
            presenting: order.wrappedValue
        ) { item in
            Button("Delete", role: .destructive) { onConfirm(item) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its mails stay where they are.")
        }
    }
}
