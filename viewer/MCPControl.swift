import Foundation
import SharedeskVNC

// Concrete MCP input tools. Parsing finishes before any event is submitted;
// malformed arguments never cause a partially constructed action to execute.
enum MCPControl {
    static let names: Set<String> = [
        "move_pointer", "click", "drag", "scroll", "press_key", "type_text"
    ]

    static var tools: [[String: Any]] {
        let coordinate: [String: Any] = ["type": "integer", "minimum": 0, "maximum": 8191]
        let button: [String: Any] = ["type": "string", "enum": ["left", "middle", "right"], "default": "left"]
        return [
            tool(
                "move_pointer",
                description: "Move the remote pointer. Coordinates are full remote-framebuffer pixels, " +
                    "not resized PNG pixels.",
                properties: ["x": coordinate, "y": coordinate],
                required: ["x", "y"]
            ),
            tool(
                "click",
                description: "Click at a remote pixel position. One or two complete clicks; no button remains held.",
                properties: [
                    "x": coordinate, "y": coordinate, "button": button,
                    "count": ["type": "integer", "minimum": 1, "maximum": 2, "default": 1]
                ],
                required: ["x", "y"]
            ),
            tool(
                "drag",
                description: "Drag between remote pixel positions over about 0.4 seconds, then release the button.",
                properties: [
                    "from_x": coordinate, "from_y": coordinate,
                    "to_x": coordinate, "to_y": coordinate, "button": button
                ],
                required: ["from_x", "from_y", "to_x", "to_y"]
            ),
            tool(
                "scroll",
                description: "Send bounded wheel steps at a remote pixel position. " +
                    "Direction describes desktop scrolling, not local viewport movement.",
                properties: [
                    "x": coordinate, "y": coordinate,
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                    "steps": ["type": "integer", "minimum": 1, "maximum": 10, "default": 1]
                ],
                required: ["x", "y", "direction"]
            ),
            tool(
                "press_key",
                description: "Press and release one key with optional Ubuntu modifiers. " +
                    "Use lowercase letters for shortcuts and explicit Shift when needed. " +
                    "Keys: one printable ASCII character, Enter, Tab, Backspace, Delete, Escape, " +
                    "Left, Right, Up, Down, Home, End, PageUp, PageDown, F1–F12. " +
                    "Super is the Ubuntu Windows/Super key.",
                properties: [
                    "key": ["type": "string", "minLength": 1, "maxLength": 12],
                    "modifiers": [
                        "type": "array", "maxItems": 4, "uniqueItems": true,
                        "items": ["type": "string", "enum": ["Control", "Alt", "Shift", "Super"]]
                    ]
                ],
                required: ["key"]
            ),
            tool(
                "type_text",
                description: "Type 1–128 printable ASCII characters, tabs or newlines using English (US) " +
                    "key events, never the clipboard. A newline presses Enter and may submit a form or " +
                    "execute a command. Unicode is rejected without sending any input.",
                properties: ["text": ["type": "string", "minLength": 1, "maxLength": 128]],
                required: ["text"]
            )
        ]
    }

    private static func tool(
        _ name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        var properties = properties
        properties["target"] = [
            "type": "object",
            "description": "Copy target from current connection status or screenshot metadata. " +
                "Old connections and changed desktop sizes are rejected.",
            "properties": [
                "connection_id": ["type": "string", "format": "uuid"],
                "width": ["type": "integer", "minimum": 1, "maximum": 8192],
                "height": ["type": "integer", "minimum": 1, "maximum": 8192]
            ],
            "required": ["connection_id", "width", "height"],
            "additionalProperties": false
        ] as [String: Any]
        return [
            "name": name,
            "description": description + " Requires Allow MCP Control. Local input revokes control. " +
                "Completion means messages were sent, not that an application accepted them.",
            "inputSchema": [
                "type": "object", "properties": properties,
                "required": ["target"] + required, "additionalProperties": false
            ],
            "annotations": [
                "readOnlyHint": false, "destructiveHint": true,
                "idempotentHint": false, "openWorldHint": true
            ]
        ]
    }

    static func plan(tool name: String, arguments: [String: Any]) throws -> VNCInputPlan {
        // The advertised property set also bounds the accepted argument names.
        guard let definition = tools.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any],
              Set(arguments.keys).isSubset(of: Set(properties.keys)) else {
            throw VNCInputError(message: "Unknown input tool or unexpected argument. Nothing was sent.")
        }
        guard let targetObject = arguments["target"] as? [String: Any],
              Set(targetObject.keys) == Set(["connection_id", "width", "height"]),
              let connectionText = targetObject["connection_id"] as? String,
              let connectionID = UUID(uuidString: connectionText) else {
            throw VNCInputError(message: "Supply target from a current screenshot or connection status.")
        }
        let width = try integer(targetObject, "width", range: 1...8192)
        let height = try integer(targetObject, "height", range: 1...8192)
        let target = VNCInputTarget(connectionID: connectionID, width: width, height: height)
        var steps: [VNCInputStep] = []

        switch name {
        case "move_pointer", "click", "scroll":
            let x = try integer(arguments, "x", range: 0...(width - 1))
            let y = try integer(arguments, "y", range: 0...(height - 1))
            switch name {
            case "move_pointer":
                steps = [VNCInputStep(events: [.pointer(x: x, y: y, buttons: 0)], delayAfter: 0)]
            case "click":
                let button = try pointerButton(arguments)
                let count = try integer(arguments, "count", range: 1...2, defaultValue: 1)
                for index in 0..<count {
                    steps.append(VNCInputStep(events: [.pointer(x: x, y: y, buttons: button)], delayAfter: 0.05))
                    steps.append(VNCInputStep(
                        events: [.pointer(x: x, y: y, buttons: 0)],
                        delayAfter: index + 1 < count ? 0.1 : 0
                    ))
                }
            default:
                let direction = try string(arguments, "direction")
                let wheel: UInt8
                switch direction {
                case "up": wheel = 8
                case "down": wheel = 16
                case "left": wheel = 32
                case "right": wheel = 64
                default: throw VNCInputError(message: "Scroll direction must be up, down, left or right.")
                }
                let count = try integer(arguments, "steps", range: 1...10, defaultValue: 1)
                for _ in 0..<count {
                    steps.append(VNCInputStep(events: [
                        .pointer(x: x, y: y, buttons: wheel),
                        .pointer(x: x, y: y, buttons: 0)
                    ], delayAfter: 0.03))
                }
            }

        case "drag":
            let fromX = try integer(arguments, "from_x", range: 0...(width - 1))
            let fromY = try integer(arguments, "from_y", range: 0...(height - 1))
            let toX = try integer(arguments, "to_x", range: 0...(width - 1))
            let toY = try integer(arguments, "to_y", range: 0...(height - 1))
            let button = try pointerButton(arguments)
            steps.append(VNCInputStep(events: [
                .pointer(x: fromX, y: fromY, buttons: 0),
                .pointer(x: fromX, y: fromY, buttons: button)
            ], delayAfter: 0.02))
            for index in 1...20 {
                let x = fromX + (toX - fromX) * index / 20
                let y = fromY + (toY - fromY) * index / 20
                steps.append(VNCInputStep(events: [.pointer(x: x, y: y, buttons: button)], delayAfter: 0.02))
            }
            steps.append(VNCInputStep(events: [.pointer(x: toX, y: toY, buttons: 0)], delayAfter: 0))

        case "press_key":
            let key = try string(arguments, "key")
            let namedKeys: [String: UInt32] = [
                "Enter": UInt32(XK_Return), "Tab": UInt32(XK_Tab), "Backspace": UInt32(XK_BackSpace),
                "Delete": UInt32(XK_Delete), "Escape": UInt32(XK_Escape),
                "Left": UInt32(XK_Left), "Right": UInt32(XK_Right),
                "Up": UInt32(XK_Up), "Down": UInt32(XK_Down),
                "Home": UInt32(XK_Home), "End": UInt32(XK_End),
                "PageUp": UInt32(XK_Page_Up), "PageDown": UInt32(XK_Page_Down)
            ]
            let symbol: UInt32
            if let named = namedKeys[key] {
                symbol = named
            } else if let index = (1...12).first(where: { key == "F\($0)" }) {
                symbol = UInt32(XK_F1) + UInt32(index - 1)
            } else if key.utf8.count == 1, let byte = key.utf8.first, (32...126).contains(byte) {
                symbol = UInt32(byte)
            } else {
                throw VNCInputError(
                    message: "Unsupported key. Use a documented key name or one printable ASCII character."
                )
            }

            var modifiers: [UInt32] = []
            if let value = arguments["modifiers"] {
                guard let names = value as? [String], names.count <= 4, Set(names).count == names.count else {
                    throw VNCInputError(
                        message: "Modifiers must be a list of distinct Control, Alt, Shift or Super names."
                    )
                }
                for name in names {
                    switch name {
                    case "Control": modifiers.append(UInt32(XK_Control_L))
                    case "Alt": modifiers.append(UInt32(XK_Alt_L))
                    case "Shift": modifiers.append(UInt32(XK_Shift_L))
                    case "Super": modifiers.append(UInt32(XK_Super_L))
                    default: throw VNCInputError(message: "Unknown modifier. Use Control, Alt, Shift or Super.")
                    }
                }
            }
            steps = keyStroke(symbol, modifiers: modifiers)

        case "type_text":
            let text = try string(arguments, "text")
            guard (1...128).contains(text.utf8.count),
                  text.utf8.allSatisfy({ (32...126).contains($0) || $0 == 9 || $0 == 10 }) else {
                throw VNCInputError(
                    message: "Text must be 1–128 printable ASCII characters, tabs or newlines. Nothing was sent."
                )
            }
            for byte in text.utf8 {
                let symbol: UInt32
                switch byte {
                case 9: symbol = UInt32(XK_Tab)
                case 10: symbol = UInt32(XK_Return)
                default: symbol = UInt32(byte)
                }
                steps.append(contentsOf: keyStroke(symbol, modifiers: []))
            }

        default:
            throw VNCInputError(message: "Unknown input tool.")
        }
        return VNCInputPlan(target: target, steps: steps)
    }

    // Both shortcuts and text characters are complete strokes. Reverse release
    // order preserves modifier ownership and never leaves a key held for a later call.
    private static func keyStroke(_ symbol: UInt32, modifiers: [UInt32]) -> [VNCInputStep] {
        let symbols = modifiers + [symbol]
        return [
            VNCInputStep(events: symbols.map { .key($0, down: true) }, delayAfter: 0.01),
            VNCInputStep(events: symbols.reversed().map { .key($0, down: false) }, delayAfter: 0.01)
        ]
    }

    private static func pointerButton(_ arguments: [String: Any]) throws -> UInt8 {
        switch try string(arguments, "button", defaultValue: "left") {
        case "left": return 1
        case "middle": return 2
        case "right": return 4
        default: throw VNCInputError(message: "Button must be left, middle or right.")
        }
    }

    private static func integer(
        _ object: [String: Any], _ key: String, range: ClosedRange<Int>, defaultValue: Int? = nil
    ) throws -> Int {
        if object[key] == nil, let defaultValue { return defaultValue }
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound),
              number.doubleValue <= Double(range.upperBound) else {
            throw VNCInputError(message: "\(key) must be an integer from \(range.lowerBound) to \(range.upperBound).")
        }
        return number.intValue
    }

    private static func string(_ object: [String: Any], _ key: String, defaultValue: String? = nil) throws -> String {
        if object[key] == nil, let defaultValue { return defaultValue }
        guard let value = object[key] as? String else {
            throw VNCInputError(message: "\(key) must be a string.")
        }
        return value
    }
}
