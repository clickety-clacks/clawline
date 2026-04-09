import type { StreamDotState } from "../../runtime/chat/chatDomainStore";

const MAX_VISIBLE_DOTS = 11;

export function StreamPageDots({
  activeSessionKey,
  onClick,
  sessionKeys,
  streamDotStateBySessionKey
}: {
  activeSessionKey?: string;
  onClick: () => void;
  sessionKeys: string[];
  streamDotStateBySessionKey: Record<string, StreamDotState>;
}) {
  const activeIndex = Math.max(
    0,
    activeSessionKey ? sessionKeys.indexOf(activeSessionKey) : 0
  );

  const visibleDotIndices =
    sessionKeys.length <= MAX_VISIBLE_DOTS
      ? sessionKeys.map((_, index) => index)
      : Array.from(
          {
            length: MAX_VISIBLE_DOTS
          },
          (_, offset) => {
            const halfWindow = Math.floor(MAX_VISIBLE_DOTS / 2);
            const maxStart = Math.max(0, sessionKeys.length - MAX_VISIBLE_DOTS);
            const start = Math.min(Math.max(0, activeIndex - halfWindow), maxStart);
            return start + offset;
          }
        );

  const showsLeadingOverflow = (visibleDotIndices[0] ?? 0) > 0;
  const showsTrailingOverflow =
    (visibleDotIndices.at(-1) ?? -1) < sessionKeys.length - 1;

  return (
    <button
      aria-label="Manage streams"
      className="stream-page-dots"
      data-testid="stream-page-dots"
      onClick={onClick}
      onPointerDown={(event) => {
        // Keep the composer focused so iOS Safari doesn't dismiss the keyboard
        // before the session popover tap completes.
        event.preventDefault();
      }}
      type="button"
    >
      <span className="sr-only">
        {`Stream ${Math.min(activeIndex + 1, Math.max(sessionKeys.length, 1))} of ${sessionKeys.length}`}
      </span>
      <span aria-hidden="true" className="stream-page-dots-track">
        {showsLeadingOverflow ? (
          <span className="stream-page-dot stream-page-dot--overflow" />
        ) : null}
        {visibleDotIndices.map((index) => {
          const sessionKey = sessionKeys[index];
          const isActive = sessionKey === activeSessionKey;
          const dotState = streamDotStateBySessionKey[sessionKey] ?? "inactive";

          return (
            <span
              className={
                isActive
                  ? "stream-page-dot stream-page-dot--active"
                  : dotState === "unread"
                    ? "stream-page-dot stream-page-dot--unread"
                    : dotState === "userTail"
                      ? "stream-page-dot stream-page-dot--user-tail"
                    : "stream-page-dot"
              }
              key={sessionKey}
            />
          );
        })}
        {showsTrailingOverflow ? (
          <span className="stream-page-dot stream-page-dot--overflow" />
        ) : null}
      </span>
    </button>
  );
}
