"use client";

import { Suspense, useEffect, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { useAuthStore } from "@/stores/auth-store";
import { Loader2, AlertCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useParams } from "next/navigation";

function OAuthCallbackInner() {
  const router = useRouter();
  const params = useParams();
  const searchParams = useSearchParams();
  const t = useTranslations("login");
  const { loginWithOAuth } = useAuthStore();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const code = searchParams.get("code");
    const state = searchParams.get("state");
    const errorParam = searchParams.get("error");

    if (errorParam) {
      setError(errorParam === "access_denied" ? "access_denied" : "token_exchange_failed");
      return;
    }

    if (!code) {
      setError("missing_params");
      return;
    }

    const savedState = sessionStorage.getItem("oauth_state");
    if (!state || state !== savedState) {
      setError("invalid_state");
      return;
    }

    const codeVerifier = sessionStorage.getItem("oauth_code_verifier");
    const serverUrl = sessionStorage.getItem("oauth_server_url");

    if (!codeVerifier || !serverUrl) {
      setError("missing_params");
      return;
    }

    const redirectUri = `${window.location.origin}/${params.locale}/auth/callback`;

    loginWithOAuth(serverUrl, code, codeVerifier, redirectUri)
      .then((success) => {
        if (success) {
          sessionStorage.removeItem("oauth_state");
          sessionStorage.removeItem("oauth_code_verifier");
          sessionStorage.removeItem("oauth_server_url");
          router.push(`/${params.locale}`);
        } else {
          setError("token_exchange_failed");
        }
      })
      .catch(() => {
        setError("token_exchange_failed");
      });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps -- OAuth callback must run exactly once on mount

  if (error) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
        <div className="w-full max-w-sm mx-auto px-4 text-center">
          <div className="inline-flex items-center justify-center w-20 h-20 rounded-2xl bg-red-500/10 mb-6">
            <AlertCircle className="w-10 h-10 text-red-500" />
          </div>
          <h1 className="text-xl font-medium text-foreground mb-2">
            {t("oauth_error.title")}
          </h1>
          <p className="text-muted-foreground text-sm mb-6">
            {t(`oauth_error.${error}`)}
          </p>
          <Button
            variant="outline"
            onClick={() => router.push(`/${params.locale}/login`)}
          >
            {t("oauth_error.back_to_login")}
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
      <div className="w-full max-w-sm mx-auto px-4 text-center" role="status">
        <Loader2 className="w-8 h-8 animate-spin text-primary mx-auto mb-4" />
        <p className="text-muted-foreground text-sm">{t("oauth_completing")}</p>
      </div>
    </div>
  );
}

export default function OAuthCallbackPage() {
  return (
    <Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
          <div className="w-full max-w-sm mx-auto px-4 text-center" role="status">
            <Loader2 className="w-8 h-8 animate-spin text-primary mx-auto mb-4" />
          </div>
        </div>
      }
    >
      <OAuthCallbackInner />
    </Suspense>
  );
}
