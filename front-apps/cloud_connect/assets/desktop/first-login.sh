#!/bin/bash
# First login password change enforcement

# Only run for the target user in interactive shells
if [ "$USER" = "diegonmarcos" ] && [ -t 0 ]; then
    # Check if password change is required
    if chage -l "$USER" 2>/dev/null | grep -q "Password expires.*: password must be changed"; then
        clear
        echo ""
        echo "╔═══════════════════════════════════════════════════════════╗"
        echo "║           CLOUD DESKTOP - FIRST LOGIN SETUP               ║"
        echo "╠═══════════════════════════════════════════════════════════╣"
        echo "║  Welcome! For security, you must change your password.    ║"
        echo "║  Your temporary password is: changeme                     ║"
        echo "╚═══════════════════════════════════════════════════════════╝"
        echo ""

        # Force password change
        passwd

        if [ $? -eq 0 ]; then
            echo ""
            echo "Password changed successfully!"
            echo "Press Enter to continue..."
            read
        else
            echo ""
            echo "Password change failed. You will be prompted again on next login."
            sleep 3
        fi
    fi
fi
