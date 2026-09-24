import React from 'react';
import { createRoot } from 'react-dom/client';
declare global { interface Window { qualification: { ready(): void } } }
const root = createRoot(document.getElementById('root')!);
root.render(React.createElement('div', null, 'synthetic qualification'));
window.qualification.ready();
