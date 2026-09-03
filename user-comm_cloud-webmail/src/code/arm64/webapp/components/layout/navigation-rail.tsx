"use client";

import { Mail, Calendar, BookUser, Settings } from "lucide-react";
import { usePathname, Link } from "@/i18n/navigation";
import { useTranslations } from "next-intl";
import { useCalendarStore } from "@/stores/calendar-store";
import { useEmailStore } from "@/stores/email-store";
import { cn } from "@/lib/utils";

interface NavItem {
  id: string;
  icon: typeof Mail;
  labelKey: string;
  href: string;
  hidden?: boolean;
  badge?: number;
}

interface NavigationRailProps {
  orientation?: "vertical" | "horizontal";
  collapsed?: boolean;
  className?: string;
}

export function NavigationRail({
  orientation = "vertical",
  collapsed = false,
  className,
}: NavigationRailProps) {
  const t = useTranslations("sidebar");
  const pathname = usePathname();
  const { supportsCalendar } = useCalendarStore();
  const { mailboxes } = useEmailStore();
  const inboxUnread = mailboxes.find(m => m.role === "inbox")?.unreadEmails || 0;

  const navItems: NavItem[] = [
    { id: "mail", icon: Mail, labelKey: "mail", href: "/", badge: inboxUnread },
    { id: "calendar", icon: Calendar, labelKey: "calendar", href: "/calendar", hidden: !supportsCalendar },
    { id: "contacts", icon: BookUser, labelKey: "contacts", href: "/contacts" },
    { id: "settings", icon: Settings, labelKey: "settings", href: "/settings" },
  ];

  const visibleItems = navItems.filter((item) => !item.hidden);

  const getIsActive = (href: string) => {
    if (href === "/") {
      return pathname === "/" || pathname === "";
    }
    return pathname.startsWith(href);
  };

  if (orientation === "horizontal") {
    return (
      <nav
        className={cn("flex items-center justify-around bg-background border-t border-border relative z-10", className)}
        role="navigation"
        aria-label={t("nav_label")}
      >
        {visibleItems.map((item) => {
          const isActive = getIsActive(item.href);
          const Icon = item.icon;
          return (
            <Link
              key={item.id}
              href={item.href}
              className={cn(
                "flex flex-col items-center justify-center gap-1 py-2 px-3 min-w-[64px] min-h-[44px]",
                "transition-colors duration-150",
                isActive
                  ? "text-primary"
                  : "text-muted-foreground hover:text-foreground"
              )}
              aria-current={isActive ? "page" : undefined}
            >
              <div className="relative">
                <Icon className="w-5 h-5" />
                {item.badge != null && item.badge > 0 && (
                  <span className="absolute -top-1.5 -right-2.5 flex items-center justify-center min-w-[16px] h-4 text-[10px] font-bold rounded-full bg-red-500 text-white px-1">
                    {item.badge > 99 ? "99+" : item.badge}
                  </span>
                )}
              </div>
              <span className="text-[10px] font-medium leading-tight">{t(item.labelKey)}</span>
            </Link>
          );
        })}
      </nav>
    );
  }

  return (
    <nav
      className={cn(
        "flex flex-col",
        collapsed ? "items-center gap-1 py-3 px-1" : "gap-0.5 py-2 px-2",
        className
      )}
      role="navigation"
      aria-label={t("nav_label")}
    >
      {visibleItems.map((item) => {
        const isActive = getIsActive(item.href);
        const Icon = item.icon;
        return (
          <Link
            key={item.id}
            href={item.href}
            className={cn(
              "relative flex items-center gap-2.5 rounded-md transition-colors duration-150",
              collapsed
                ? "justify-center w-10 h-10"
                : "px-2.5 py-1.5 text-sm",
              "max-lg:min-h-[44px]",
              isActive
                ? "bg-primary/10 text-primary font-medium"
                : "text-muted-foreground hover:bg-muted hover:text-foreground"
            )}
            aria-current={isActive ? "page" : undefined}
            title={collapsed ? t(item.labelKey) : undefined}
          >
            <Icon className={cn("w-[18px] h-[18px] flex-shrink-0", isActive && "text-primary")} />
            {!collapsed && <span className="truncate">{t(item.labelKey)}</span>}
            {item.badge != null && item.badge > 0 && (
              <span className={cn(
                "absolute flex items-center justify-center min-w-[16px] h-4 text-[10px] font-bold rounded-full bg-red-500 text-white px-1",
                collapsed ? "-top-0.5 -right-0.5" : "right-1.5"
              )}>
                {item.badge > 99 ? "99+" : item.badge}
              </span>
            )}
          </Link>
        );
      })}
    </nav>
  );
}
