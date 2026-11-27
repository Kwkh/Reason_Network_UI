interface IconProps {
  size?: number;
}

function frame(size: number) {
  return {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.8,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    "aria-hidden": true,
  };
}

export function SendIcon({ size = 18 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M4 12l16-8-6 16-2.5-6.5L4 12z" />
    </svg>
  );
}

export function PlusIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

export function LinkIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M10 13a5 5 0 0 0 7.07 0l2-2a5 5 0 0 0-7.07-7.07l-1.1 1.1" />
      <path d="M14 11a5 5 0 0 0-7.07 0l-2 2A5 5 0 0 0 12 20.07l1.1-1.1" />
    </svg>
  );
}

export function RefreshIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M20 11a8 8 0 1 0-2.3 5.7" />
      <path d="M20 4v7h-7" />
    </svg>
  );
}

export function FolderIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7z" />
    </svg>
  );
}

export function ReplyIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M9 14L4 9l5-5" />
      <path d="M4 9h9a7 7 0 0 1 7 7v3" />
    </svg>
  );
}

export function CloseIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M6 6l12 12M18 6L6 18" />
    </svg>
  );
}

export function UsersIcon({ size = 16 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <circle cx="9" cy="8" r="3" />
      <path d="M3 20a6 6 0 0 1 12 0" />
      <path d="M16 5a3 3 0 0 1 0 6M18 20a6 6 0 0 0-3-5.2" />
    </svg>
  );
}

export function CheckIcon({ size = 14 }: IconProps) {
  return (
    <svg {...frame(size)}>
      <path d="M4 12l5 5L20 6" />
    </svg>
  );
}
