import React from 'react';
import { createRoot } from 'react-dom/client';
import 'bootstrap-icons/font/bootstrap-icons.css';
import './styles.css';
import App from './App';
import { installClientLogging } from './services/clientLogger';

installClientLogging();
createRoot(document.getElementById('root')).render(<App />);
