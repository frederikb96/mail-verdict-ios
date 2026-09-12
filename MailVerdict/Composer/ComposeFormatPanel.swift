import MailVerdictKit
import UIKit

/// The format panel the Aa button swaps in for the keyboard — the Mail idiom. Every item acts on
/// the selection immediately and shows whether it is active there.
final class ComposeFormatPanel: UIInputView {

    private var buttons: [ComposeFormatItem: UIButton] = [:]
    private let onSelect: (ComposeFormatItem) -> Void

    init(onSelect: @escaping (ComposeFormatItem) -> Void) {
        self.onSelect = onSelect
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 260), inputViewStyle: .keyboard)

        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = 8
        rows.distribution = .fillEqually
        rows.translatesAutoresizingMaskIntoConstraints = false
        for items in ComposeFormatItem.rows {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillEqually
            for item in items {
                let button = makeButton(for: item)
                buttons[item] = button
                row.addArrangedSubview(button)
            }
            rows.addArrangedSubview(row)
        }
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            rows.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            rows.heightAnchor.constraint(equalToConstant: 4 * 44 + 3 * 8),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ state: ComposeFormatState) {
        for (item, button) in buttons {
            button.isSelected = item.isActive(in: state)
        }
    }

    private func makeButton(for item: ComposeFormatItem) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.image = UIImage(systemName: item.symbol)
        configuration.cornerStyle = .medium
        if item == .clearFormatting {
            configuration.title = item.title
            configuration.imagePadding = 8
        }
        let button = UIButton(
            configuration: configuration,
            primaryAction: UIAction { [weak self] _ in self?.onSelect(item) })
        button.accessibilityLabel = item.title
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseBackgroundColor = button.isSelected ? .tintColor : .secondarySystemFill
            updated?.baseForegroundColor = button.isSelected ? .white : .label
            button.configuration = updated
        }
        return button
    }
}
