#!/bin/bash
#
# Script : sync_ntfs_archive_to_xattr.sh
# Objectif : Synchroniser l'attribut NTFS "Archive" en xattr Linux "user.archive" ou "user.noarchive"
# Auteur : Pour Johnny
# Version : 2.0 - Optimisée
#################################################

# Codes couleurs ANSI
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
RESET='\033[0m'

##############################
# CONFIGURATION
##############################
# Chemin local où ton partage SMB est monté
MOUNT_POINT="/mnt/partage"
# Partage SMB complet pour smbinfo (exemple //IP_SERVEUR/NOM_PARTAGE)
SMB_SHARE="//192.168.1.100/partage"
# User SMB pour interrogation (doit avoir accès en lecture)
SMB_USER="ton_user"
# Dossier temporaire pour logs
LOG_DIR="./logs"
# Configuration email
EMAIL_TO="destinataire@example.com"
EMAIL_FROM="systeme@example.com"
EMAIL_SUBJECT="Rapport de synchronisation NTFS Archive"

# Définir le niveau de parallélisme (nombre de processus simultanés)
PARALLEL_JOBS=8

# Vérifier si les commandes nécessaires sont disponibles
check_dependencies() {
    local missing=0
    for cmd in find xargs setfattr smbinfo msmtp grep awk; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${RED}[ERREUR]${RESET} Commande '$cmd' non trouvée. Veuillez l'installer." >&2
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        exit 1
    fi
}

# Fonction de logging
log() {
    local level="$1"
    local message="$2"
    local color=""
    
    case "$level" in
        "INFO") color="${GREEN}" ;;
        "WARN") color="${YELLOW}" ;;
        "ERROR") color="${RED}" ;;
        "DEBUG") color="${CYAN}" ;;
        *) color="${RESET}" ;;
    esac
    
    echo -e "${color}[$level]${RESET} $message"
    echo "[$level] $message" >> "$LOG_FILE"
}

# Vérifier que le point de montage est accessible
check_mount_point() {
    if [ ! -d "$MOUNT_POINT" ]; then
        log "ERROR" "Le point de montage $MOUNT_POINT n'existe pas."
        exit 1
    fi
    
    if ! mountpoint -q "$MOUNT_POINT"; then
        log "WARN" "$MOUNT_POINT n'est pas un point de montage valide."
    fi
}

# Traiter un fichier
process_file() {
    local fichier="$1"
    local relative_path="${fichier#$MOUNT_POINT/}"
    
    # Utilisation de smbinfo pour lire les File Attributes
    local ATTRIBUTES
    ATTRIBUTES=$(smbinfo filebasicinfo "$SMB_SHARE/$relative_path" --user="$SMB_USER" 2>/dev/null | grep "File Attributes" | awk '{print $3}')
    
    if [[ -z "$ATTRIBUTES" ]]; then
        log "WARN" "Impossible de lire les attributs pour $fichier"
        return 1
    fi
    
    # Convertir l'attribut de hexadécimal en décimal
    local DEC_ATTRIBUTES=$((16#$ATTRIBUTES))
    
    # Vérifier si le bit Archive (0x20) est présent
    if (( ($DEC_ATTRIBUTES & 0x20) == 0x20 )); then
        # Archive est SET
        setfattr -n user.archive -v 1 "$fichier" 2>/dev/null
        setfattr -x user.noarchive "$fichier" 2>/dev/null
        log "INFO" "user.archive=1 posé sur $relative_path"
        echo "$relative_path" >> "$ARCHIVE_FILES"
    else
        # Archive est UNSET
        setfattr -n user.noarchive -v 1 "$fichier" 2>/dev/null
        setfattr -x user.archive "$fichier" 2>/dev/null
        log "INFO" "user.noarchive=1 posé sur $relative_path"
        echo "$relative_path" >> "$NOARCHIVE_FILES"
    fi
}

export -f process_file
export LOG_FILE
export SMB_SHARE
export SMB_USER
export MOUNT_POINT
export ARCHIVE_FILES
export NOARCHIVE_FILES
export -f log

# Envoi du rapport par email
send_email_report() {
    local total_files=$1
    local archive_files=$2
    local noarchive_files=$3
    local errors=$4
    local duration=$5
    
    {
        echo "Subject: $EMAIL_SUBJECT"
        echo "From: $EMAIL_FROM"
        echo "To: $EMAIL_TO"
        echo "Content-Type: text/html; charset=UTF-8"
        echo
        echo "<html><body style='font-family: Arial, sans-serif;'>"
        echo "<h2>Rapport de synchronisation NTFS Archive</h2>"
        echo "<p>Exécuté le $(date)</p>"
        echo "<hr>"
        echo "<h3>Résumé</h3>"
        echo "<ul>"
        echo "<li><strong>Fichiers traités:</strong> $total_files</li>"
        echo "<li><strong>Fichiers avec Archive SET:</strong> $archive_files</li>"
        echo "<li><strong>Fichiers avec Archive UNSET:</strong> $noarchive_files</li>"
        echo "<li><strong>Erreurs rencontrées:</strong> $errors</li>"
        echo "<li><strong>Durée d'exécution:</strong> $duration</li>"
        echo "</ul>"
        echo "<hr>"
        echo "<p><em>Ce message a été généré automatiquement.</em></p>"
        echo "</body></html>"
    } | msmtp --from="$EMAIL_FROM" "$EMAIL_TO"
    
    if [ $? -eq 0 ]; then
        log "INFO" "Rapport email envoyé avec succès à $EMAIL_TO"
    else
        log "ERROR" "Échec de l'envoi du rapport email"
    fi
}

##############################
# SCRIPT PRINCIPAL
##############################
# Vérifier les dépendances
check_dependencies

# Création des dossiers nécessaires
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/sync_xattr_$(date +%Y%m%d_%H%M%S).log"
ARCHIVE_FILES="$LOG_DIR/archive_files_$(date +%Y%m%d_%H%M%S).txt"
NOARCHIVE_FILES="$LOG_DIR/noarchive_files_$(date +%Y%m%d_%H%M%S).txt"
ERROR_LOG="$LOG_DIR/errors_$(date +%Y%m%d_%H%M%S).txt"

# Vérifier le point de montage
check_mount_point

# Initialiser les fichiers
> "$ARCHIVE_FILES"
> "$NOARCHIVE_FILES"
> "$ERROR_LOG"

# Marquer le début de l'exécution
START_TIME=$(date +%s)
log "INFO" "===== DÉBUT DE LA SYNCHRONISATION ====="
log "INFO" "Point de montage: $MOUNT_POINT"
log "INFO" "Partage SMB: $SMB_SHARE"

# Traitement parallèle des fichiers
echo -e "${MAGENTA}Recherche des fichiers...${RESET}"
find "$MOUNT_POINT" -type f -print0 | xargs -0 -n1 -P "$PARALLEL_JOBS" -I{} bash -c 'process_file "$@"' _ {} 2>>"$ERROR_LOG"

# Statistiques
END_TIME=$(date +%s)
EXECUTION_TIME=$((END_TIME - START_TIME))
DURATION=$(date -u -d @${EXECUTION_TIME} +"%T")

TOTAL_FILES=$(wc -l < <(cat "$ARCHIVE_FILES" "$NOARCHIVE_FILES" 2>/dev/null))
ARCHIVE_COUNT=$(wc -l < "$ARCHIVE_FILES" 2>/dev/null || echo 0)
NOARCHIVE_COUNT=$(wc -l < "$NOARCHIVE_FILES" 2>/dev/null || echo 0)
ERROR_COUNT=$(grep -c "" "$ERROR_LOG" 2>/dev/null || echo 0)

# Résumé final
log "INFO" "===== FIN DE LA SYNCHRONISATION ====="
log "INFO" "Fichiers traités: $TOTAL_FILES"
log "INFO" "Fichiers avec Archive SET: $ARCHIVE_COUNT"
log "INFO" "Fichiers avec Archive UNSET: $NOARCHIVE_COUNT"
log "INFO" "Erreurs rencontrées: $ERROR_COUNT"
log "INFO" "Durée d'exécution: $DURATION"

# Envoi du rapport par email
send_email_report "$TOTAL_FILES" "$ARCHIVE_COUNT" "$NOARCHIVE_COUNT" "$ERROR_COUNT" "$DURATION"

echo -e "${GREEN}===== SYNCHRONISATION TERMINÉE =====${RESET}"
echo -e "${BLUE}Rapport complet disponible dans:${RESET} $LOG_FILE"
echo -e "${BLUE}Durée d'exécution:${RESET} $DURATION"
exit 0
