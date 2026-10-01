import React from "react";

/**
 * Jot's glyph set — inline SVG, stroke-based, round caps (SF Symbols-like).
 * One component, switched by `name`.
 */
export function JotGlyph({ name, size = 24, color = "currentColor" }) {
  const sp = { width: size, height: size, fill: "none" };
  switch (name) {
    case "mic": return (
      <svg {...sp} viewBox="0 0 60 60">
        <rect x="23" y="9" width="14" height="26" rx="7" fill={color}></rect>
        <path d="M16 28c0 7.7 6.3 14 14 14s14-6.3 14-14" stroke={color} strokeWidth="3.4" strokeLinecap="round"></path>
        <path d="M30 42v8" stroke={color} strokeWidth="3.4" strokeLinecap="round"></path>
        <path d="M22.5 51h15" stroke={color} strokeWidth="3.4" strokeLinecap="round"></path>
      </svg>);
    case "keyboard": return (
      <svg {...sp} viewBox="0 0 64 64">
        <rect x="6" y="17" width="52" height="30" rx="7" stroke={color} strokeWidth="3.2"></rect>
        <g fill={color}>
          <rect x="13" y="24" width="5" height="5" rx="1.4"></rect><rect x="23" y="24" width="5" height="5" rx="1.4"></rect>
          <rect x="33" y="24" width="5" height="5" rx="1.4"></rect><rect x="43" y="24" width="5" height="5" rx="1.4"></rect>
          <rect x="13" y="32" width="5" height="5" rx="1.4"></rect><rect x="23" y="32" width="5" height="5" rx="1.4"></rect>
          <rect x="33" y="32" width="5" height="5" rx="1.4"></rect><rect x="43" y="32" width="5" height="5" rx="1.4"></rect>
          <rect x="18" y="39.5" width="28" height="4.5" rx="2.2"></rect>
        </g>
      </svg>);
    case "check": return (
      <svg {...sp} viewBox="0 0 64 64">
        <path d="M14 33.5l12.5 12.5L50 19" stroke={color} strokeWidth="7" strokeLinecap="round" strokeLinejoin="round"></path>
      </svg>);
    case "sparkle": return (
      <svg {...sp} viewBox="0 0 64 64">
        <path d="M32 4c1.6 10.5 4.8 17.6 9.9 22.1C46.6 30.2 53.5 32.4 60 32c-10.5 1.6-17.6 4.8-22.1 9.9C34.2 46.2 32 53.5 32 60c-1.6-10.5-4.8-17.6-9.9-22.1C18 33.8 10.5 31.6 4 32c10.5-1.6 17.6-4.8 22.1-9.9C30.2 17.4 31.6 10.5 32 4z" fill={color}></path>
        <path d="M51.5 7c.5 3.4 1.5 5.7 3.2 7.2C56.3 15.7 58.6 16.4 61 16c-3.4.5-5.7 1.5-7.2 3.2C52.2 20.7 51.5 23 52 25c-.5-3.4-1.5-5.7-3.2-7.2C47.2 16.3 44.9 15.6 43 16c3.4-.5 5.7-1.5 7.2-3.2C51.7 11.3 51.1 9 51.5 7z" fill={color} opacity="0.9"></path>
      </svg>);
    case "chevron-left": return (
      <svg width={size * 0.6} height={size} viewBox="0 0 13 22" fill="none">
        <path d="M10 2L2 11l8 9" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"></path>
      </svg>);
    case "chevron-right": return (
      <svg width={size * 0.6} height={size} viewBox="0 0 13 22" fill="none">
        <path d="M3 2l8 9-8 9" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"></path>
      </svg>);
    case "close": return (
      <svg {...sp} viewBox="0 0 17 17">
        <path d="M2 2l13 13M15 2L2 15" stroke={color} strokeWidth="2.4" strokeLinecap="round"></path>
      </svg>);
    case "arrow-up": return (
      <svg {...sp} viewBox="0 0 24 24">
        <path d="M12 20V5M5.5 11.5L12 5l6.5 6.5" stroke={color} strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round"></path>
      </svg>);
    case "doc": return (
      <svg {...sp} viewBox="0 0 24 24">
        <path d="M7 3h7l4 4v14H7z" stroke={color} strokeWidth="1.8" strokeLinejoin="round"></path>
        <path d="M9.5 12h5M9.5 15.5h5" stroke={color} strokeWidth="1.8" strokeLinecap="round"></path>
      </svg>);
    case "copy": return (
      <svg {...sp} viewBox="0 0 24 24">
        <rect x="8" y="8" width="12" height="12" rx="2.5" stroke={color} strokeWidth="1.9"></rect>
        <path d="M5 15.5A2.5 2.5 0 0 1 4 13.5V6a2 2 0 0 1 2-2h7.5A2.5 2.5 0 0 1 15.5 5" stroke={color} strokeWidth="1.9" strokeLinecap="round"></path>
      </svg>);
    case "trash": return (
      <svg {...sp} viewBox="0 0 24 24">
        <path d="M4.5 6.5h15M9.5 6V4.6c0-.9.7-1.6 1.6-1.6h1.8c.9 0 1.6.7 1.6 1.6V6M7 6.5l.9 13c.1.9.8 1.5 1.7 1.5h4.8c.9 0 1.6-.6 1.7-1.5l.9-13" stroke={color} strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round"></path>
        <path d="M10.2 10.5l.3 7M13.8 10.5l-.3 7" stroke={color} strokeWidth="1.9" strokeLinecap="round"></path>
      </svg>);
    case "pause": return (
      <svg {...sp} viewBox="0 0 24 24">
        <rect x="6.5" y="4.5" width="4" height="15" rx="1.6" fill={color}></rect>
        <rect x="13.5" y="4.5" width="4" height="15" rx="1.6" fill={color}></rect>
      </svg>);
    case "globe": return (
      <svg {...sp} viewBox="0 0 24 24">
        <circle cx="12" cy="12" r="9.2" stroke={color} strokeWidth="1.7"></circle>
        <path d="M2.8 12h18.4M12 2.8c2.7 2.5 4.2 5.8 4.2 9.2s-1.5 6.7-4.2 9.2c-2.7-2.5-4.2-5.8-4.2-9.2S9.3 5.3 12 2.8z" stroke={color} strokeWidth="1.7"></path>
      </svg>);
    case "search": return (
      <svg {...sp} viewBox="0 0 24 24">
        <circle cx="10.5" cy="10.5" r="6.7" stroke={color} strokeWidth="2"></circle>
        <path d="M15.6 15.6L21 21" stroke={color} strokeWidth="2" strokeLinecap="round"></path>
      </svg>);
    case "keyboard-mini": return (
      <svg {...sp} viewBox="0 0 24 24">
        <rect x="2.5" y="7" width="19" height="11" rx="2.5" stroke={color} strokeWidth="1.7"></rect>
        <path d="M8 15h8" stroke={color} strokeWidth="1.7" strokeLinecap="round"></path>
        <g fill={color}><rect x="5.4" y="9.6" width="1.9" height="1.9" rx="0.6"></rect><rect x="9" y="9.6" width="1.9" height="1.9" rx="0.6"></rect><rect x="12.6" y="9.6" width="1.9" height="1.9" rx="0.6"></rect><rect x="16.2" y="9.6" width="1.9" height="1.9" rx="0.6"></rect></g>
      </svg>);
    case "watch": return (
      <svg width={size} height={size * (60 / 48)} viewBox="0 0 48 60" fill="none">
        <path d="M17 8l1.4-3.4A3 3 0 0 1 21.2 3h5.6a3 3 0 0 1 2.8 1.6L31 8M17 52l1.4 3.4A3 3 0 0 0 21.2 57h5.6a3 3 0 0 0 2.8-1.6L31 52" stroke={color} strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" opacity="0.5"></path>
        <rect x="11" y="9" width="26" height="42" rx="9" stroke={color} strokeWidth="2.6"></rect>
        <rect x="37" y="24" width="3.4" height="9" rx="1.7" fill={color}></rect>
        <g stroke={color} strokeWidth="2.4" strokeLinecap="round">
          <line x1="18" y1="27" x2="18" y2="33"></line><line x1="22" y1="23.5" x2="22" y2="36.5"></line>
          <line x1="26" y1="26" x2="26" y2="34"></line><line x1="30" y1="28.5" x2="30" y2="31.5"></line>
        </g>
      </svg>);
    default: return null;
  }
}
