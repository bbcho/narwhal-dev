public enum DesktopMoveDirection: String, Equatable, Sendable {
    case left
    case right
}

public enum DesktopMoveError: Error, Equatable, Sendable {
    case activeDesktopMissing
    case noAdjacentDesktop(DesktopMoveDirection)
}

public func adjacentDesktopSpace(
    in spaces: [SpaceID],
    active: SpaceID,
    direction: DesktopMoveDirection
) -> Result<SpaceID, DesktopMoveError> {
    guard let activeIndex = spaces.firstIndex(of: active) else {
        return .failure(.activeDesktopMissing)
    }

    let destinationIndex: Int
    switch direction {
    case .left:
        destinationIndex = activeIndex - 1
    case .right:
        destinationIndex = activeIndex + 1
    }
    guard spaces.indices.contains(destinationIndex) else {
        return .failure(.noAdjacentDesktop(direction))
    }
    return .success(spaces[destinationIndex])
}
