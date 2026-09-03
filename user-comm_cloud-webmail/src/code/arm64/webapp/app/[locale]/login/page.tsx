"use client";

import { useState, useEffect, useRef } from "react";
import { useRouter } from "@/i18n/navigation";
import { useParams } from "next/navigation";
import { useTranslations } from "next-intl";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAuthStore } from "@/stores/auth-store";
import { useConfig } from "@/hooks/use-config";
import { cn } from "@/lib/utils";
import { Mail, AlertCircle, Loader2, X, Info, Eye, EyeOff, LogIn } from "lucide-react";
import { discoverOAuth, type OAuthMetadata } from "@/lib/oauth/discovery";
import { generateCodeVerifier, generateCodeChallenge, generateState } from "@/lib/oauth/pkce";
import { OAUTH_SCOPES } from "@/lib/oauth/tokens";

export default function LoginPage() {
  const router = useRouter();
  const t = useTranslations("login");
  const params = useParams();
  const { login, isLoading, error, clearError, isAuthenticated } = useAuthStore();
  const { appName, jmapServerUrl: serverUrl, oauthEnabled, oauthClientId, oauthIssuerUrl, oauthOnly, rememberMeEnabled, isLoading: configLoading, error: configError } = useConfig();

  const [formData, setFormData] = useState({
    username: "",
    password: "",
  });
  const [totpCode, setTotpCode] = useState("");
  const [showTotpField, setShowTotpField] = useState(false);
  const [rememberMe, setRememberMe] = useState(false);
  const [sessionExpired, setSessionExpired] = useState(false);
  const [showPassword, setShowPassword] = useState(false);
  const [shakeError, setShakeError] = useState(false);

  const [savedUsernames, setSavedUsernames] = useState<string[]>([]);
  const [showSuggestions, setShowSuggestions] = useState(false);
  const [filteredSuggestions, setFilteredSuggestions] = useState<string[]>([]);
  const [selectedSuggestionIndex, setSelectedSuggestionIndex] = useState(-1);
  const [oauthMetadata, setOauthMetadata] = useState<OAuthMetadata | null>(null);
  const [oauthDiscoveryDone, setOauthDiscoveryDone] = useState(false);
  const [oauthLoading, setOauthLoading] = useState(false);
  const [oauthRetryCount, setOauthRetryCount] = useState(0);
  const [oauthLocalError, setOauthLocalError] = useState<string | null>(null);

  const suggestionsRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const justSelectedSuggestion = useRef(false);
  const totpInputRef = useRef<HTMLInputElement>(null);
  const prevError = useRef<string | null>(null);

  useEffect(() => {
    if (serverUrl) {
      document.title = appName;
    }
  }, [appName, serverUrl]);

  useEffect(() => {
    try {
      if (sessionStorage.getItem('session_expired') === 'true') {
        setSessionExpired(true);
        sessionStorage.removeItem('session_expired');
      }
    } catch { /* sessionStorage unavailable */ }
  }, []);

  useEffect(() => {
    if (error && error !== prevError.current) {
      setShakeError(true);
      const timer = setTimeout(() => setShakeError(false), 400);
      return () => clearTimeout(timer);
    }
    prevError.current = error;
  }, [error]);

  useEffect(() => {
    if (!serverUrl) return;
    const saved = localStorage.getItem("webmail_usernames");
    if (saved) {
      try {
        const usernames = JSON.parse(saved);
        setSavedUsernames(usernames);
      } catch {
        return;
      }
    }
  }, [serverUrl]);

  useEffect(() => {
    if (isAuthenticated) {
      router.push('/');
    }
  }, [isAuthenticated, router]);

  useEffect(() => {
    clearError();
  }, [formData, clearError]);

  useEffect(() => {
    if (!serverUrl) return;
    if (justSelectedSuggestion.current) {
      justSelectedSuggestion.current = false;
      return;
    }

    if (formData.username && savedUsernames.length > 0) {
      const filtered = savedUsernames.filter(username =>
        username.toLowerCase().includes(formData.username.toLowerCase())
      );
      setFilteredSuggestions(filtered);
      setShowSuggestions(filtered.length > 0);
    } else if (formData.username === "" && savedUsernames.length > 0) {
      setFilteredSuggestions(savedUsernames);
      setShowSuggestions(false);
    } else {
      setShowSuggestions(false);
    }
    setSelectedSuggestionIndex(-1);
  }, [formData.username, savedUsernames, serverUrl]);

  useEffect(() => {
    if (!serverUrl) return;
    const handleClickOutside = (event: MouseEvent) => {
      if (suggestionsRef.current && !suggestionsRef.current.contains(event.target as Node) &&
          inputRef.current && !inputRef.current.contains(event.target as Node)) {
        setShowSuggestions(false);
      }
    };

    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, [serverUrl]);

  useEffect(() => {
    if (!oauthEnabled || !serverUrl) return;
    discoverOAuth(oauthIssuerUrl || serverUrl)
      .then((metadata) => {
        setOauthMetadata(metadata);
        setOauthDiscoveryDone(true);
      })
      .catch(() => {
        setOauthMetadata(null);
        setOauthDiscoveryDone(true);
      });
  }, [oauthEnabled, serverUrl, oauthIssuerUrl, oauthRetryCount]);

  if (configLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
        <div className="w-full max-w-sm mx-auto px-4 text-center" role="status">
          <Loader2 className="w-8 h-8 animate-spin text-primary mx-auto" />
          <span className="sr-only">{t("loading")}</span>
        </div>
      </div>
    );
  }

  if (configError) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
        <div className="w-full max-w-sm mx-auto px-4 text-center">
          <div className="inline-flex items-center justify-center w-20 h-20 rounded-2xl bg-red-500/10 mb-6">
            <AlertCircle className="w-10 h-10 text-red-500" />
          </div>
          <h1 className="text-xl font-medium text-foreground mb-2">{t("config_error.title")}</h1>
          <p className="text-muted-foreground text-sm">
            {t("config_error.fetch_failed")}
          </p>
        </div>
      </div>
    );
  }

  if (!serverUrl) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
        <div className="w-full max-w-sm mx-auto px-4 text-center">
          <div className="inline-flex items-center justify-center w-20 h-20 rounded-2xl bg-red-500/10 mb-6">
            <AlertCircle className="w-10 h-10 text-red-500" />
          </div>
          <h1 className="text-xl font-medium text-foreground mb-2">{t("config_error.title")}</h1>
          <p className="text-muted-foreground text-sm">
            {t("config_error.server_not_configured")}
          </p>
        </div>
      </div>
    );
  }

  const saveUsername = (username: string) => {
    const saved = localStorage.getItem("webmail_usernames");
    let usernames: string[] = [];

    if (saved) {
      try {
        usernames = JSON.parse(saved);
      } catch {
        usernames = [];
      }
    }

    if (!usernames.includes(username)) {
      usernames = [username, ...usernames].slice(0, 5);
      localStorage.setItem("webmail_usernames", JSON.stringify(usernames));
      setSavedUsernames(usernames);
    }
  };

  const removeUsername = (username: string, e: React.MouseEvent) => {
    e.stopPropagation();
    const updated = savedUsernames.filter(u => u !== username);
    localStorage.setItem("webmail_usernames", JSON.stringify(updated));
    setSavedUsernames(updated);
    setFilteredSuggestions(updated.filter(u =>
      u.toLowerCase().includes(formData.username.toLowerCase())
    ));
  };

  const handleUsernameChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setFormData({ ...formData, username: e.target.value });
  };

  const handleUsernameFocus = () => {
    if (savedUsernames.length > 0 && formData.username === "") {
      setFilteredSuggestions(savedUsernames);
      setShowSuggestions(true);
    } else if (filteredSuggestions.length > 0) {
      setShowSuggestions(true);
    }
  };

  const selectSuggestion = (username: string) => {
    justSelectedSuggestion.current = true;
    setFormData({ ...formData, username });
    setShowSuggestions(false);
    document.getElementById("password")?.focus();
  };

  const handleKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (!showSuggestions || filteredSuggestions.length === 0) return;

    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelectedSuggestionIndex(prev =>
        prev < filteredSuggestions.length - 1 ? prev + 1 : prev
      );
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelectedSuggestionIndex(prev => prev > 0 ? prev - 1 : -1);
    } else if (e.key === "Enter" && selectedSuggestionIndex >= 0) {
      e.preventDefault();
      selectSuggestion(filteredSuggestions[selectedSuggestionIndex]);
    } else if (e.key === "Escape") {
      setShowSuggestions(false);
      setSelectedSuggestionIndex(-1);
    }
  };

  const handleOAuthLogin = async () => {
    if (!oauthMetadata || !oauthClientId) return;

    // PKCE needs Web Crypto (SubtleCrypto.digest). That API is only exposed
    // in secure contexts — i.e. HTTPS or localhost. Fail loudly before we
    // try to call it so the user sees a fix-this message instead of a
    // mystery "crypto.subtle is undefined" TypeError.
    if (typeof window === "undefined" || !window.isSecureContext || typeof crypto?.subtle?.digest !== "function") {
      setOauthLocalError(t("oauth_error.requires_https"));
      return;
    }

    setOauthLocalError(null);
    setOauthLoading(true);

    const verifier = generateCodeVerifier();
    const challenge = await generateCodeChallenge(verifier);
    const state = generateState();
    const redirectUri = `${window.location.origin}/${params.locale}/auth/callback`;

    sessionStorage.setItem("oauth_code_verifier", verifier);
    sessionStorage.setItem("oauth_state", state);
    sessionStorage.setItem("oauth_server_url", serverUrl!);

    const authUrl = new URL(oauthMetadata.authorization_endpoint);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("client_id", oauthClientId);
    authUrl.searchParams.set("redirect_uri", redirectUri);
    authUrl.searchParams.set("scope", OAUTH_SCOPES);
    authUrl.searchParams.set("state", state);
    authUrl.searchParams.set("code_challenge", challenge);
    authUrl.searchParams.set("code_challenge_method", "S256");

    window.location.href = authUrl.toString();
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (oauthOnly) return;

    const success = await login(
      serverUrl,
      formData.username,
      formData.password,
      totpCode || undefined,
      rememberMe
    );

    if (success) {
      saveUsername(formData.username);
      router.push('/');
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-gradient-to-br from-background via-background to-muted/20">
      <div className="w-full max-w-sm mx-auto px-4">
        {/* Logo */}
        <div className="text-center mb-12">
          <div className="inline-flex items-center justify-center w-20 h-20 rounded-2xl bg-gradient-to-br from-primary/10 to-primary/5 mb-6 shadow-lg shadow-primary/5">
            <Mail className="w-10 h-10 text-primary" />
          </div>
          <h1 className="text-3xl font-light text-foreground tracking-tight">
            {appName}
          </h1>
        </div>

        {/* Session Expired Banner */}
        {sessionExpired && (
          <div
            className="mb-6 p-4 bg-blue-500/10 border border-blue-500/20 rounded-lg flex items-start gap-3"
            role="status"
            aria-live="polite"
          >
            <Info className="w-5 h-5 text-blue-600 dark:text-blue-400 flex-shrink-0 mt-0.5" />
            <p className="text-sm text-blue-700 dark:text-blue-300 flex-1">
              {t("session_expired")}
            </p>
            <button
              type="button"
              onClick={() => setSessionExpired(false)}
              className="p-0.5 rounded hover:bg-blue-500/10 transition-colors flex-shrink-0"
              aria-label={t("dismiss")}
            >
              <X className="w-4 h-4 text-blue-600 dark:text-blue-400" />
            </button>
          </div>
        )}

        {/* Error Message */}
        {error && (
          <div className="mb-6 p-4 bg-red-500/10 border border-red-500/20 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-red-500 flex-shrink-0 mt-0.5" />
            <p className="text-sm text-red-600 dark:text-red-400">
              {error === 'invalid_credentials' && showTotpField && totpCode
                ? t('error.totp_invalid')
                : t(`error.${error}`) || t("error.generic")}
            </p>
          </div>
        )}

        {oauthLocalError && (
          <div className="mb-6 p-4 bg-amber-500/10 border border-amber-500/20 rounded-lg flex items-start gap-3">
            <AlertCircle className="w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5" />
            <p className="text-sm text-amber-700 dark:text-amber-300">{oauthLocalError}</p>
          </div>
        )}

        {/* Login Form */}
        <form
          onSubmit={handleSubmit}
          className={cn("space-y-4", shakeError && "animate-shake")}
        >
          {!oauthOnly && (<>
          <fieldset disabled={isLoading} className="space-y-4">
            <div className="relative">
              <Input
                ref={inputRef}
                id="username"
                type="text"
                value={formData.username}
                onChange={handleUsernameChange}
                onFocus={handleUsernameFocus}
                onKeyDown={handleKeyDown}
                className="h-12 px-4 bg-secondary/50 border-border/50 focus:bg-secondary focus:border-primary/50 transition-colors"
                placeholder={t("username_placeholder")}
                required
                autoComplete="off"
                data-form-type="other"
                data-lpignore="true"
                autoFocus
              />

              {/* Custom autocomplete dropdown */}
              {showSuggestions && filteredSuggestions.length > 0 && (
                <div
                  ref={suggestionsRef}
                  className="absolute top-full mt-1 w-full bg-secondary border border-border rounded-md shadow-lg z-50 overflow-hidden"
                >
                  {filteredSuggestions.map((username, index) => (
                    <div
                      key={username}
                      className={cn(
                        "px-4 py-2.5 flex items-center justify-between hover:bg-muted cursor-pointer transition-colors",
                        index === selectedSuggestionIndex && "bg-muted"
                      )}
                      onClick={() => selectSuggestion(username)}
                    >
                      <span className="text-sm text-foreground">{username}</span>
                      <button
                        type="button"
                        onClick={(e) => removeUsername(username, e)}
                        className="p-1 hover:bg-background rounded transition-colors"
                        title={t("remove_from_history")}
                      >
                        <X className="w-3 h-3 text-muted-foreground" />
                      </button>
                    </div>
                  ))}
                </div>
              )}
            </div>

            <div className="relative">
              <Input
                id="password"
                type={showPassword ? "text" : "password"}
                value={formData.password}
                onChange={(e) => setFormData({ ...formData, password: e.target.value })}
                className="h-12 px-4 pr-11 bg-secondary/50 border-border/50 focus:bg-secondary focus:border-primary/50 transition-colors"
                placeholder={t("password_placeholder")}
                required
                autoComplete="current-password"
              />
              <button
                type="button"
                onClick={() => setShowPassword(!showPassword)}
                className="absolute right-3 top-1/2 -translate-y-1/2 p-1 rounded text-muted-foreground hover:text-foreground transition-colors"
                aria-label={showPassword ? t("hide_password") : t("show_password")}
                tabIndex={-1}
              >
                {showPassword ? (
                  <EyeOff className="w-4.5 h-4.5" />
                ) : (
                  <Eye className="w-4.5 h-4.5" />
                )}
              </button>
            </div>

            {!showTotpField ? (
              <button
                type="button"
                onClick={() => {
                  setShowTotpField(true);
                  setTimeout(() => totpInputRef.current?.focus(), 50);
                }}
                className="text-xs text-muted-foreground hover:text-foreground transition-colors text-left"
              >
                {t("totp_toggle")}
              </button>
            ) : (
              <Input
                ref={totpInputRef}
                id="totp"
                type="text"
                inputMode="numeric"
                maxLength={6}
                value={totpCode}
                onChange={(e) => setTotpCode(e.target.value.replace(/\D/g, ''))}
                className="h-10 px-4 bg-secondary/50 border-border/50 focus:bg-secondary focus:border-primary/50 transition-colors text-center font-mono tracking-widest"
                placeholder={t("totp_placeholder")}
                autoComplete="one-time-code"
                aria-label={t("totp_label")}
              />
            )}

            {rememberMeEnabled && (
              <label className="flex items-center gap-2.5 cursor-pointer group select-none">
                <span className="relative flex items-center justify-center">
                  <input
                    type="checkbox"
                    checked={rememberMe}
                    onChange={(e) => setRememberMe(e.target.checked)}
                    className="peer sr-only"
                  />
                  <span className="flex items-center justify-center w-4.5 h-4.5 rounded border border-border bg-secondary/50 peer-checked:bg-primary peer-checked:border-primary peer-focus-visible:ring-2 peer-focus-visible:ring-ring peer-focus-visible:ring-offset-2 peer-focus-visible:ring-offset-background transition-colors">
                    {rememberMe && (
                      <svg className="w-3 h-3 text-primary-foreground" viewBox="0 0 12 12" fill="none">
                        <path d="M2 6L5 9L10 3" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
                      </svg>
                    )}
                  </span>
                </span>
                <span className="text-sm text-muted-foreground group-hover:text-foreground transition-colors">
                  {t("remember_me")}
                </span>
              </label>
            )}
          </fieldset>

          <Button
            type="submit"
            className="w-full h-12 font-medium text-base bg-primary hover:bg-primary/90 transition-all duration-200 shadow-lg shadow-primary/20"
            disabled={isLoading}
          >
            {isLoading ? (
              <div className="flex items-center gap-2">
                <Loader2 className="w-4 h-4 animate-spin" />
                {t("signing_in")}
              </div>
            ) : (
              t("sign_in")
            )}
          </Button>
          </>)}

          {oauthMetadata && (
            <>
              {!oauthOnly && (
                <div className="relative my-6">
                  <div className="absolute inset-0 flex items-center">
                    <span className="w-full border-t border-border" />
                  </div>
                  <div className="relative flex justify-center text-xs uppercase">
                    <span className="bg-background px-2 text-muted-foreground">{t("or")}</span>
                  </div>
                </div>
              )}

              <Button
                type="button"
                variant={oauthOnly ? "default" : "outline"}
                className={cn(
                  "w-full h-12 font-medium text-base",
                  oauthOnly && "bg-primary hover:bg-primary/90 shadow-lg shadow-primary/20"
                )}
                onClick={handleOAuthLogin}
                disabled={oauthLoading || isLoading}
                autoFocus={oauthOnly}
              >
                {oauthLoading ? (
                  <Loader2 className="w-4 h-4 animate-spin mr-2" />
                ) : (
                  <LogIn className="w-4 h-4 mr-2" />
                )}
                {t("sign_in_sso")}
              </Button>
            </>
          )}

          {oauthEnabled && oauthDiscoveryDone && !oauthMetadata && (
            <div className="mt-4 p-3 bg-amber-500/10 border border-amber-500/20 rounded-lg flex items-start gap-2">
              <AlertCircle className="w-4 h-4 text-amber-700 dark:text-amber-400 flex-shrink-0 mt-0.5" />
              <div className="flex-1">
                <p className="text-sm text-amber-700 dark:text-amber-400">
                  {t("error.oauth_discovery_failed")}
                </p>
                <button
                  type="button"
                  onClick={() => {
                    setOauthDiscoveryDone(false);
                    setOauthRetryCount((c) => c + 1);
                  }}
                  className="mt-2 text-xs font-medium text-amber-700 dark:text-amber-400 underline hover:no-underline"
                >
                  {t("retry")}
                </button>
              </div>
            </div>
          )}
        </form>
      </div>
    </div>
  );
}
