declare const MAIN_WINDOW_VITE_DEV_SERVER_URL: string | undefined;
declare const MAIN_WINDOW_VITE_NAME: string;
declare module 'react' { const React: any; export default React; export const createElement: any; }
declare module 'react-dom/client' { export const createRoot: any; }
declare module 'better-sqlite3' { const Database: any; export default Database; }
