"use client";

import { useEffect, useRef, useState } from "react";
import { useTranslations } from "next-intl";
import { MoreVertical, Users, Download, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  ContextMenu,
  ContextMenuItem,
  ContextMenuSeparator,
} from "@/components/ui/context-menu";

interface ContactBulkActionsMenuProps {
  onBulkAddToGroup: () => void;
  onBulkExport: () => void;
  onBulkDelete: () => void;
}

export function ContactBulkActionsMenu({
  onBulkAddToGroup,
  onBulkExport,
  onBulkDelete,
}: ContactBulkActionsMenuProps) {
  const t = useTranslations("contacts");
  const [isOpen, setIsOpen] = useState(false);
  const [position, setPosition] = useState({ x: 0, y: 0 });
  const menuRef = useRef<HTMLDivElement | null>(null);
  const triggerRef = useRef<HTMLButtonElement | null>(null);

  const updateMenuPosition = () => {
    const triggerRect = triggerRef.current?.getBoundingClientRect();
    if (!triggerRect) return;
    const menuWidth = 200;
    const viewportPadding = 8;
    const x = Math.max(
      viewportPadding,
      Math.min(triggerRect.right - menuWidth, window.innerWidth - menuWidth - viewportPadding)
    );
    const y = Math.min(triggerRect.bottom + 4, window.innerHeight - viewportPadding);
    setPosition({ x, y });
  };

  useEffect(() => {
    if (!isOpen) return;

    const handleClickOutside = (event: MouseEvent) => {
      const target = event.target as Node;
      if (menuRef.current?.contains(target)) return;
      if (triggerRef.current?.contains(target)) return;
      setIsOpen(false);
    };

    const handleResize = () => {
      if (!isOpen) return;
      if (!triggerRef.current) {
        setIsOpen(false);
        return;
      }
      updateMenuPosition();
    };

    const handleEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") setIsOpen(false);
    };

    updateMenuPosition();
    document.addEventListener("mousedown", handleClickOutside);
    document.addEventListener("keydown", handleEscape);
    window.addEventListener("resize", handleResize);
    window.addEventListener("scroll", handleResize, true);
    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
      document.removeEventListener("keydown", handleEscape);
      window.removeEventListener("resize", handleResize);
      window.removeEventListener("scroll", handleResize, true);
    };
  }, [isOpen]);

  const handleAction = (action: () => void) => {
    action();
    setIsOpen(false);
  };

  const handleToggle = () => {
    if (isOpen) {
      setIsOpen(false);
      return;
    }
    updateMenuPosition();
    setIsOpen(true);
  };

  return (
    <div>
      <Button
        ref={triggerRef}
        variant="outline"
        size="sm"
        onClick={handleToggle}
        className="h-7 text-xs px-2"
        aria-expanded={isOpen}
        aria-haspopup="menu"
        data-testid="contact-bulk-actions-trigger"
      >
        {t("bulk.actions")}
        <MoreVertical className="w-3.5 h-3.5 ml-1.5" />
      </Button>

      <ContextMenu
        ref={menuRef}
        isOpen={isOpen}
        position={position}
        onClose={() => setIsOpen(false)}
      >
        <ContextMenuItem
          icon={Users}
          label={t("bulk.add_to_group")}
          onClick={() => handleAction(onBulkAddToGroup)}
        />
        <ContextMenuItem
          icon={Download}
          label={t("bulk.export")}
          onClick={() => handleAction(onBulkExport)}
        />
        <ContextMenuSeparator />
        <ContextMenuItem
          icon={Trash2}
          label={t("bulk.delete")}
          onClick={() => handleAction(onBulkDelete)}
          destructive
        />
      </ContextMenu>
    </div>
  );
}
