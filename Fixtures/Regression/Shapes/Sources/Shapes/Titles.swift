/// Bodies that are one `switch` / `if` expression whose branches are calls.
public enum Tab {
    case home, settings, other

    func text(_ value: String) -> String {
        return value
    }

    public var title: String {
        switch self {
        case .home: text("Home")
        case .settings: text("Settings")
        default: text("Other")
        }
    }

    public var subtitle: String {
        if self == .home { text("H") } else { text("X") }
    }
}

/// The branches have different types; the return type unifies them.
public protocol Shape {
    var sides: Int { get }
}

struct Circle: Shape {
    let sides = 0
}

struct Square: Shape {
    let sides = 4
}

public func shape(round: Bool) -> any Shape {
    return round ? Circle() : Square()
}
