import React from "react";
import ReactDOM from "react-dom/client";
import { RouterProvider } from "react-router-dom";
import { createAppRouter } from "./routes";
import { AppProviders } from "./AppProviders";
import "./styles.css";

const rootElement = document.getElementById("root");

if (!rootElement) {
  throw new Error("Missing #root element");
}

ReactDOM.createRoot(rootElement).render(
  <React.StrictMode>
    <AppProviders>
      <RouterProvider router={createAppRouter()} />
    </AppProviders>
  </React.StrictMode>
);
