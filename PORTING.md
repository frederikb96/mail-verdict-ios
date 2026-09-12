# Porting backlog

Deferred parity work against [mail-verdict](https://github.com/frederikb96/mail-verdict)'s web
UI — entries that need an Xcode/simulator or a real device to verify, never a field, an enum case
or a `CodingKey`. Those are cheap and get ported immediately, not listed here. Append-only: add an
entry, never edit or reorder another agent's.

## Entry format

```
### <what> — web anchor: <path or symbol>
Needs a device because: <one line>
```

Remove an entry once it is ported. A backlog that keeps finished work reads as a list of things
still owed, and the next agent either redoes them or stops trusting the file.

## Backlog

Empty — nothing has been ported yet.
