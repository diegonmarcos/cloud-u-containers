"use client";

import { useTranslations, useFormatter } from "next-intl";
import { Button } from "@/components/ui/button";
import { ChevronLeft, ChevronRight, Plus, Upload } from "lucide-react";
import { addDays, startOfWeek } from "date-fns";
import { cn } from "@/lib/utils";
import type { CalendarViewMode } from "@/stores/calendar-store";

interface CalendarToolbarProps {
  selectedDate: Date;
  viewMode: CalendarViewMode;
  onPrev: () => void;
  onNext: () => void;
  onToday: () => void;
  onViewModeChange: (mode: CalendarViewMode) => void;
  onCreateEvent: () => void;
  onImport?: () => void;
  isMobile?: boolean;
  firstDayOfWeek?: number;
  onNavigateBack?: () => void;
}

export function CalendarToolbar({
  selectedDate,
  viewMode,
  onPrev,
  onNext,
  onToday,
  onViewModeChange,
  onCreateEvent,
  onImport,
  isMobile,
  firstDayOfWeek = 1,
}: CalendarToolbarProps) {
  const t = useTranslations("calendar");
  const formatter = useFormatter();
  const views: CalendarViewMode[] = ["month", "week", "day", "agenda"];

  const getDateLabel = (): string => {
    switch (viewMode) {
      case "month":
        return formatter.dateTime(selectedDate, { month: "long", year: "numeric" });
      case "week": {
        const ws = startOfWeek(selectedDate, { weekStartsOn: firstDayOfWeek as 0 | 1 });
        const we = addDays(ws, 6);
        const sameMonth = ws.getMonth() === we.getMonth();
        if (sameMonth) {
          return `${formatter.dateTime(ws, { month: "short", day: "numeric" })} – ${formatter.dateTime(we, { day: "numeric" })}, ${we.getFullYear()}`;
        }
        return `${formatter.dateTime(ws, { month: "short", day: "numeric" })} – ${formatter.dateTime(we, { month: "short", day: "numeric" })}, ${we.getFullYear()}`;
      }
      case "day":
        return formatter.dateTime(selectedDate, { weekday: "long", month: "long", day: "numeric", year: "numeric" });
      case "agenda":
        return formatter.dateTime(selectedDate, { month: "long", year: "numeric" });
    }
  };

  return (
    <div className="flex items-center gap-2 px-4 py-3 border-b border-border flex-wrap">
      <div className="flex items-center gap-1">
        <button onClick={onPrev} className="p-1.5 rounded hover:bg-muted transition-colors" aria-label={t("nav_prev")}>
          <ChevronLeft className="w-4 h-4" />
        </button>
        <span className="text-sm font-medium min-w-[140px] text-center">
          {getDateLabel()}
        </span>
        <button onClick={onNext} className="p-1.5 rounded hover:bg-muted transition-colors" aria-label={t("nav_next")}>
          <ChevronRight className="w-4 h-4" />
        </button>
      </div>

      <Button variant="outline" size="sm" onClick={onToday}>
        {t("views.today")}
      </Button>

      <div className="flex-1" />

      {!isMobile && (
        <div className="flex border border-border rounded-md overflow-hidden">
          {views.map((v) => (
            <button
              key={v}
              onClick={() => onViewModeChange(v)}
              title={t(`views.${v}_hint`)}
              className={cn(
                "px-3 py-1.5 text-xs font-medium transition-colors",
                v === viewMode
                  ? "bg-primary text-primary-foreground"
                  : "hover:bg-muted text-muted-foreground"
              )}
            >
              {t(`views.${v}`)}
            </button>
          ))}
        </div>
      )}

      {onImport && (
        <Button variant="outline" size="sm" onClick={onImport}>
          <Upload className="w-4 h-4 mr-1" />
          {!isMobile && t("import.title")}
        </Button>
      )}

      <Button size="sm" onClick={onCreateEvent}>
        <Plus className="w-4 h-4 mr-1" />
        {!isMobile && t("events.create")}
      </Button>
    </div>
  );
}
