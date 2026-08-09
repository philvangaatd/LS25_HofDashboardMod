--[[
    LS25 Hof-Dashboard – v5 Identitaets-Bridge
    ==========================================
    Uebergangsschicht fuer den technischen Rename von
    FS25_AutoDriveFlurkarte / AutoDriveFlurkarteLive auf
    FS25_HofDashboard / HofDashboardLive.

    Der eigentliche Collector-Code bleibt in diesem Migrationsschritt funktional
    unveraendert. Alle extern sichtbaren Identitaetsdaten werden bereits auf v5
    umgestellt. Die alte globale Klasse bleibt nur temporaer als Kompatibilitaetsalias
    bestehen, bis der interne Source-Rename abgeschlossen ist.
]]

if AutoDriveFlurkarteLive == nil then
    print("[FS25_HofDashboard] HofDashboardIdentity: Kernmodul nicht geladen")
    return
end

HofDashboardLive = AutoDriveFlurkarteLive

HofDashboardLive.MOD_NAME     = "FS25_HofDashboard"
HofDashboardLive.VERSION      = "5.0.0"
HofDashboardLive.SETTINGS_DIR = "LS25HofDashboard"
HofDashboardLive.OUTPUT_FILE  = "liveData.json"
