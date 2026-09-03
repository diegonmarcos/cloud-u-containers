"use client";

import { useState } from "react";
import { useTranslations } from "next-intl";
import { Reply, ReplyAll, Archive, Trash2, MoreHorizontal, Forward, Star, MailOpen, ShieldAlert, X } from "lucide-react";

interface MobileActionBarProps {
  onReply: () => void;
  onReplyAll: () => void;
  onArchive: () => void;
  onDelete: () => void;
  onForward: () => void;
  onStar: () => void;
  onMarkUnread: () => void;
  onSpam: () => void;
}

export function MobileActionBar({
  onReply, onReplyAll, onArchive, onDelete,
  onForward, onStar, onMarkUnread, onSpam,
}: MobileActionBarProps) {
  const t = useTranslations('email_viewer.mobile_actions');
  const [showMore, setShowMore] = useState(false);

  return (
    <>
      {showMore && (
        <div
          className="fixed inset-0 z-40 bg-black/30"
          onClick={() => setShowMore(false)}
          onKeyDown={(e) => e.key === 'Escape' && setShowMore(false)}
        />
      )}

      {showMore && (
        <div
          className="fixed bottom-14 left-0 right-0 z-50 bg-background border-t border-border rounded-t-xl shadow-lg"
          role="menu"
          aria-label={t('more')}
        >
          <div className="p-2 space-y-1">
            {[
              { icon: Forward, label: t('forward'), action: onForward },
              { icon: Star, label: t('star'), action: onStar },
              { icon: MailOpen, label: t('mark_unread'), action: onMarkUnread },
              { icon: ShieldAlert, label: t('spam'), action: onSpam },
            ].map(({ icon: Icon, label, action }) => (
              <button
                key={label}
                className="flex items-center gap-3 w-full px-4 py-3 text-sm rounded-lg hover:bg-accent text-foreground"
                onClick={() => { action(); setShowMore(false); }}
                role="menuitem"
              >
                <Icon className="h-5 w-5 text-muted-foreground" />
                {label}
              </button>
            ))}
          </div>
          <button
            className="flex items-center justify-center w-full py-3 border-t border-border text-muted-foreground"
            onClick={() => setShowMore(false)}
          >
            <X className="h-5 w-5" />
          </button>
        </div>
      )}

      <div
        className="fixed bottom-0 left-0 right-0 z-30 lg:hidden bg-background border-t border-border h-14 flex items-center justify-around px-2"
        role="toolbar"
        aria-label="Email actions"
      >
        {[
          { icon: Reply, label: t('reply'), action: onReply },
          { icon: ReplyAll, label: t('reply_all'), action: onReplyAll },
          { icon: Archive, label: t('archive'), action: onArchive },
          { icon: Trash2, label: t('delete'), action: onDelete },
          { icon: MoreHorizontal, label: t('more'), action: () => setShowMore(prev => !prev) },
        ].map(({ icon: Icon, label, action }) => (
          <button
            key={label}
            className="flex flex-col items-center justify-center gap-0.5 px-3 py-1 text-muted-foreground hover:text-foreground"
            onClick={action}
            aria-label={label}
          >
            <Icon className="h-5 w-5" />
            <span className="text-[10px]">{label}</span>
          </button>
        ))}
      </div>
    </>
  );
}
