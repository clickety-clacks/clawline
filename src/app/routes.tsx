import {
  createBrowserRouter,
  createHashRouter,
  Navigate,
  Outlet
} from "react-router-dom";
import { PairingScreen } from "../features/auth/PairingScreen";
import { ChatRoute } from "../features/chat/ChatRoute";
import { useAuthSessionStore } from "../runtime/auth/authSessionStore";

function RootGate() {
  const { state } = useAuthSessionStore();

  if (state.status === "ready" && state.session?.token) {
    return <Navigate to="/chat" replace />;
  }

  return <Navigate to="/pair" replace />;
}

function RootLayout() {
  return <Outlet />;
}

export function createAppRouter() {
  const createRouter =
    typeof window !== "undefined" && window.location.protocol === "file:"
      ? createHashRouter
      : createBrowserRouter;

  return createRouter([
    {
      path: "/",
      element: <RootLayout />,
      children: [
        { index: true, element: <RootGate /> },
        { path: "pair", element: <PairingScreen /> },
        { path: "chat/:sessionKey?", element: <ChatRoute /> }
      ]
    }
  ]);
}
