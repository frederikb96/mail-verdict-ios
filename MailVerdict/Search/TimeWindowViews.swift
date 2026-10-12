import MailVerdictKit
import SwiftUI

/// The clock button beside the search field: a menu of presets plus the slider overlay and the
/// custom range form, and Clear while a window is active.
struct TimeWindowMenu: View {
    let window: MVTimeWindow?
    let onSelect: (MVTimeWindow?) -> Void
    let onSlider: () -> Void
    let onCustom: () -> Void

    var body: some View {
        Menu {
            ForEach(MVTimeWindow.Preset.allCases, id: \.self) { preset in
                Button {
                    onSelect(.preset(preset))
                } label: {
                    Label(preset.title, systemImage: window == .preset(preset) ? "checkmark" : "")
                }
            }
            Button("Slider…", systemImage: "slider.horizontal.3", action: onSlider)
            Button("Custom…", systemImage: "calendar", action: onCustom)
            if window != nil {
                Divider()
                Button("Clear", systemImage: "xmark.circle", role: .destructive) { onSelect(nil) }
            }
        } label: {
            Image(systemName: "clock")
                .font(.body.weight(.medium))
                .foregroundStyle(window == nil ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(window.map { "Time window: \($0.label)" } ?? "Time window")
    }
}

/// The active window as a chip that clears it when tapped.
struct TimeWindowChip: View {
    let window: MVTimeWindow
    let onClear: () -> Void

    var body: some View {
        Button(action: onClear) {
            Chip(text: window.label, tint: .accentColor, trailingSymbol: "xmark")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear time window \(window.label)")
    }
}

/// Full-screen dimmed backdrop with one large card holding the two-thumb slider. A tap on the
/// backdrop, the X button, Escape or Return all close it and keep the current selection; a drag
/// applies on release rather than on every tick.
struct TimeSliderOverlay: View {
    let initial: ClosedRange<Int>
    let onCommit: (ClosedRange<Int>) -> Void
    let onDismiss: () -> Void

    @State private var draft: ClosedRange<Int>
    /// Fixed for the lifetime of the overlay so the axis labels do not shift while it is open.
    @State private var now = Date()

    init(
        initial: ClosedRange<Int>, onCommit: @escaping (ClosedRange<Int>) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initial = initial
        self.onCommit = onCommit
        self.onDismiss = onDismiss
        self._draft = State(initialValue: initial)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)

            card
                .padding(.horizontal, 16)

            keyboardShortcuts
        }
        .presentationBackground(.clear)
    }

    private var card: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Time window").font(.headline)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Close")
            }
            Text(MVTimeWindow.slider(startStop: draft.lowerBound, endStop: draft.upperBound, now: now).label)
                .font(.title3.monospacedDigit().weight(.semibold))
                .frame(maxWidth: .infinity)
            TimeRangeSlider(selection: $draft, now: now) { onCommit($0) }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    /// Hardware-keyboard Escape and Return, which close the overlay like the backdrop does.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("Close", action: onDismiss).keyboardShortcut(.cancelAction)
            Button("Done", action: onDismiss).keyboardShortcut(.defaultAction)
        }
        .opacity(0)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// A two-thumb slider over the fixed 52-week axis. The whole track is the touch target: a drag
/// grabs whichever thumb is nearer to where the finger went down and follows the finger, so
/// neither thumb has to be hit precisely.
private struct TimeRangeSlider: View {
    @Binding var selection: ClosedRange<Int>
    let now: Date
    let onRelease: (ClosedRange<Int>) -> Void

    private enum Thumb { case lower, upper }
    @State private var grabbed: Thumb?

    private let thumbSize: CGFloat = 40
    private let trackHeight: CGFloat = 10
    private let stops = MVTimeWindow.sliderStops

    var body: some View {
        GeometryReader { proxy in
            let inset = thumbSize / 2
            let span = max(proxy.size.width - thumbSize, 1)
            let position = { (stop: Int) -> CGFloat in inset + span * CGFloat(stop) / CGFloat(stops) }

            ZStack(alignment: .topLeading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(height: trackHeight)
                    .padding(.horizontal, inset)
                    .offset(y: (thumbSize - trackHeight) / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: position(selection.upperBound) - position(selection.lowerBound), height: trackHeight)
                    .offset(x: position(selection.lowerBound), y: (thumbSize - trackHeight) / 2)

                ForEach(MVTimeWindow.monthMarks(now: now), id: \.stop) { mark in
                    VStack(spacing: 0) {
                        Text(mark.label)
                        if let year = mark.year {
                            Text(String(year)).fontWeight(.semibold)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .position(x: position(mark.stop), y: thumbSize + 20)
                }

                thumb.position(x: position(selection.lowerBound), y: thumbSize / 2)
                thumb.position(x: position(selection.upperBound), y: thumbSize / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let stop = stopIndex(at: value.location.x, inset: inset, span: span)
                        if grabbed == nil {
                            grabbed =
                                abs(value.startLocation.x - position(selection.lowerBound))
                                    <= abs(value.startLocation.x - position(selection.upperBound)) ? .lower : .upper
                        }
                        move(grabbed, to: stop)
                    }
                    .onEnded { _ in
                        grabbed = nil
                        onRelease(selection)
                    }
            )
        }
        .frame(height: thumbSize + 44)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time range")
        .accessibilityValue(
            MVTimeWindow.slider(startStop: selection.lowerBound, endStop: selection.upperBound, now: now).label
        )
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1 : -1
            move(.upper, to: selection.upperBound + step)
            onRelease(selection)
        }
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color.accentColor, lineWidth: 3))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: thumbSize, height: thumbSize)
    }

    private func stopIndex(at x: CGFloat, inset: CGFloat, span: CGFloat) -> Int {
        let fraction = (x - inset) / span
        return min(max(Int((fraction * CGFloat(stops)).rounded()), 0), stops)
    }

    /// Keeps at least one stop between the thumbs: the dragged thumb stops at the other one.
    private func move(_ thumb: Thumb?, to stop: Int) {
        switch thumb {
        case .lower:
            selection = min(max(stop, 0), selection.upperBound - 1)...selection.upperBound
        case .upper:
            selection = selection.lowerBound...min(max(stop, selection.lowerBound + 1), stops)
        case nil:
            break
        }
    }
}

/// Start and end day entered as `YYYY-MM-DD` whatever the device's locale, both days inclusive.
struct CustomRangeSheet: View {
    let initial: (start: MVCalendarDay, end: MVCalendarDay)
    let onApply: (MVTimeWindow) -> Void
    let onCancel: () -> Void

    @State private var startText: String
    @State private var endText: String

    init(
        initial: (start: MVCalendarDay, end: MVCalendarDay), onApply: @escaping (MVTimeWindow) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.initial = initial
        self.onApply = onApply
        self.onCancel = onCancel
        self._startText = State(initialValue: initial.start.description)
        self._endText = State(initialValue: initial.end.description)
    }

    private var start: MVCalendarDay? { MVCalendarDay(isoString: startText.trimmingCharacters(in: .whitespaces)) }
    private var end: MVCalendarDay? { MVCalendarDay(isoString: endText.trimmingCharacters(in: .whitespaces)) }

    private var window: MVTimeWindow? {
        guard let start, let end, start <= end else { return nil }
        return .custom(since: start, until: end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Start", text: $startText, isValid: start != nil)
                    field("End", text: $endText, isValid: end != nil)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Custom range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { if let window { onApply(window) } }
                        .disabled(window == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var footer: String {
        if start != nil, end != nil, window == nil { return "The start day must not be after the end day." }
        return "Year-month-day, for example 2026-10-12. Both days are included."
    }

    private func field(_ title: String, text: Binding<String>, isValid: Bool) -> some View {
        LabeledContent(title) {
            TextField("YYYY-MM-DD", text: text)
                .keyboardType(.numbersAndPunctuation)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .foregroundStyle(isValid ? Color.primary : Color.red)
        }
    }
}
