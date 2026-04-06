import { useEffect } from "react";
import { X } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { useAuthSessionStore } from "../../runtime/auth/authSessionStore";
import {
  type AppearanceMode,
  type FontScale,
  useSettingsStore
} from "../../runtime/settings/settingsStore";

const APPEARANCE_OPTIONS: AppearanceMode[] = ["dark", "light", "system"];
const FONT_SCALE_OPTIONS: FontScale[] = ["compact", "default", "comfortable"];

export function SettingsDrawer({
  isOpen,
  onClose
}: {
  isOpen: boolean;
  onClose: () => void;
}) {
  const navigate = useNavigate();
  const { state: authState, store: authStore } = useAuthSessionStore();
  const { state, store } = useSettingsStore();

  useEffect(() => {
    document.documentElement.dataset.appearance = state.appearance;
    document.documentElement.style.setProperty(
      "--font-scale",
      state.fontScale === "compact"
        ? "0.94"
        : state.fontScale === "comfortable"
          ? "1.08"
          : "1"
    );
  }, [state.appearance, state.fontScale]);

  if (!isOpen) {
    return null;
  }

  return (
    <div className="drawer-backdrop" onClick={onClose} role="presentation">
      <aside
        aria-label="Settings"
        className="settings-drawer"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="settings-header">
          <div>
            <p className="eyebrow">Settings</p>
            <h2>Appearance and diagnostics</h2>
          </div>
          <button
            aria-label="Close settings"
            className="button-secondary button-icon"
            onClick={onClose}
            type="button"
          >
            <X size={18} strokeWidth={2.1} />
          </button>
        </div>

        <section className="settings-section">
          <h3>Appearance</h3>
          <div className="segmented-control">
            {APPEARANCE_OPTIONS.map((option) => (
              <button
                className={option === state.appearance ? "segment active" : "segment"}
                key={option}
                onClick={() => store.setAppearance(option)}
                type="button"
              >
                {option}
              </button>
            ))}
          </div>
        </section>

        <section className="settings-section">
          <h3>Font scale</h3>
          <div className="segmented-control">
            {FONT_SCALE_OPTIONS.map((option) => (
              <button
                className={option === state.fontScale ? "segment active" : "segment"}
                key={option}
                onClick={() => store.setFontScale(option)}
                type="button"
              >
                {option}
              </button>
            ))}
          </div>
        </section>

        <section className="settings-section">
          <label className="toggle-row">
            <span>Show connection diagnostics</span>
            <input
              checked={state.diagnostics}
              onChange={(event) => store.setDiagnostics(event.target.checked)}
              type="checkbox"
            />
          </label>
        </section>

        <section className="settings-section settings-section--meta">
          <p>Signed in as {authState.session?.claimedName ?? "Unknown browser"}</p>
          <p>{authState.session?.serverUrl ?? "No provider"}</p>
        </section>

        <button
          className="button-danger"
          onClick={() => {
            authStore.logout();
            navigate("/pair", { replace: true });
          }}
          type="button"
        >
          Log out
        </button>
      </aside>
    </div>
  );
}
