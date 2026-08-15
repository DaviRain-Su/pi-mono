const session_overlay = @import("coding_agent").session_overlay;
const session_manager = @import("coding_agent").session_manager;

pub const SessionChoice = session_overlay.SessionChoice;
pub const SessionOverlay = session_overlay.SessionOverlay;
pub const SessionScope = session_overlay.SessionScope;
pub const SessionSortMode = session_overlay.SessionSortMode;
pub const SessionNameFilter = session_overlay.SessionNameFilter;
pub const SessionInfo = session_manager.SessionSearchInfo;
pub const SessionListProgress = struct {
    current: usize = 0,
    total: ?usize = null,
};

pub const loadSessionPicker = session_overlay.load;
pub const refreshSessionPicker = session_overlay.refresh;

test "session picker cli module re-exports overlay picker state" {
    _ = SessionChoice;
    _ = loadSessionPicker;
}
