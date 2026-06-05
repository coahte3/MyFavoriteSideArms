#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#pragma newdecls required
#pragma semicolon 1

// 1.12の厳密なコンパイルチェックを通すための正しい2次元配列の宣言
char g_szFavoriteMelee[MAXPLAYERS + 1][32]; 
bool g_bAutoEquip[MAXPLAYERS + 1];
int g_iLastMenuSelection[MAXPLAYERS + 1];
bool g_bHasLoadedThisMap[MAXPLAYERS + 1]; // 各プレイヤー個別の「このマップで既にファイルロードされたか」のフラグ

// ガチランダム抽選用の全14種類の正確な内部武器IDリスト
static const char g_szMeleeList[][] = {
    "knife", "frying_pan", "katana", "machete", "fireaxe", "crowbar", 
    "baseball_bat", "cricket_bat", "electric_guitar", "tonfa", "golfclub", 
    "shovel", "pitchfork", "riotshield"
};

public Plugin myinfo = {
    name = "My Favorite SideArms 1.0",
    author = "coah&GoogleAI&BigSister", 
    description = "Perfect Secondary Weapon Save & Auto-Equip System",
    version = "1.2.5",
    url = ""
};

public void OnPluginStart()
{
    RegConsoleCmd("sm_melee", Command_MeleeMain, "Open SideArms Weapon Menu");
    HookEvent("round_start", Event_RoundStart, EventHookMode_Post);
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);

    // すでにゲーム内にいるプレイヤー用の保険フックのみ
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
        {
            SDKHook(i, SDKHook_OnTakeDamage, OnTakeDamage);
            SDKHook(i, SDKHook_TraceAttack, OnTraceAttack);
        }
    }
}

public void OnMapStart()
{
    // ライオットシールドの3Dモデルデータをマップ開始時に強制プリロード（アンロック）
    if (!IsModelPrecached("models/w_models/weapons/w_riotshield.mdl")) {
        PrecacheModel("models/w_models/weapons/w_riotshield.mdl", true);
    }
}

// サーバー入室時 (フライング自爆ロードや初期化はすべて撤廃し、SDKフックのみ安全に行う)
public void OnClientPostAdminCheck(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
    SDKHook(client, SDKHook_TraceAttack, OnTraceAttack);
    ResetClientData(client);
}

public void OnClientDisconnect(int client)
{
    ResetClientData(client);
}

void ResetClientData(int client)
{
    g_szFavoriteMelee[client][0] = '\0'; // 初期状態は完全に「none(空文字)」
    g_bAutoEquip[client] = true;
    g_iLastMenuSelection[client] = 0;
    g_bHasLoadedThisMap[client] = false;
}

// 禁止文字を安全なアンダーバーに一括置換する関数
void CleanFileName(char[] buffer, int maxlen)
{
    ReplaceString(buffer, maxlen, ":", "_"); ReplaceString(buffer, maxlen, "/", "_");
    ReplaceString(buffer, maxlen, "\\", "_"); ReplaceString(buffer, maxlen, "*", "_");
    ReplaceString(buffer, maxlen, "?", "_"); ReplaceString(buffer, maxlen, "\"", "_");
    ReplaceString(buffer, maxlen, "<", "_"); ReplaceString(buffer, maxlen, ">", "_");
    ReplaceString(buffer, maxlen, "|", "_");
}

// ------------------------------------------------------------------
// データ保存 / 読み込みシステム (デバフと同じく、確実なファイルI/Oに修正)
// ------------------------------------------------------------------

bool GetPlayerSavePath(int client, char[] path, int maxlen)
{
    char auth[64];
    if (!GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth))) {
        // ローカル環境での一時的な保留(PENDING)対策
        if (client == 1 && !IsDedicatedServer()) Format(auth, sizeof(auth), "STEAM_LocalHost_1");
        else GetClientName(client, auth, sizeof(auth));
    }
    CleanFileName(auth, sizeof(auth));

    char dir[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, dir, sizeof(dir), "data/sidearms");
    if (!DirExists(dir)) CreateDirectory(dir, 511);
    
    BuildPath(Path_SM, path, maxlen, "data/sidearms/%s.txt", auth);
    return true;
}

void SavePlayerData(int client)
{
    if (IsFakeClient(client)) return;
    
    char path[PLATFORM_MAX_PATH];
    if (!GetPlayerSavePath(client, path, sizeof(path))) return;
    
    File file = OpenFile(path, "w");
    if (file != null) {
        file.WriteLine("%s", g_bAutoEquip[client] ? "1" : "0"); 
        file.WriteLine("%s", g_szFavoriteMelee[client]); 
        delete file;
    }
}

void LoadPlayerData(int client)
{
    if (IsFakeClient(client)) return;
    
    char path[PLATFORM_MAX_PATH];
    if (!GetPlayerSavePath(client, path, sizeof(path))) return;
    
    if (FileExists(path)) {
        File file = OpenFile(path, "r");
        if (file != null) {
            char line[16]; 
            file.ReadLine(line, sizeof(line)); TrimString(line); 
            g_bAutoEquip[client] = !StrEqual(line, "0");
            
            // 2次元配列のプレイヤー個別の部屋に、保存されていたお気に入り武器の文字列を正しくロード
            file.ReadLine(g_szFavoriteMelee[client], 32); 
            TrimString(g_szFavoriteMelee[client]); 
            delete file;
        }
    } else {
        // ファイルが存在しない新規プレイヤーの初期値は「none(空文字)」を徹底維持
        g_szFavoriteMelee[client][0] = '\0';
        g_bAutoEquip[client] = true;
    }
}

// ------------------------------------------------------------------
// イベントハンドラ (デバフプラグインで大成功した『純粋スポーン依存型』に一本化)
// ------------------------------------------------------------------

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++) {
        g_bHasLoadedThisMap[i] = false; // 全滅リスタートやマップ開始時に、ロード完了フラグをリセット
    }
}

// ★修正：プレイヤーが画面に出現した「その瞬間」にのみ全てを依存させる方式
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || GetClientTeam(client) != 2) return;

    if (IsPlayerAlive(client)) {
        // マップ開始後（またはラウンド開始後）、このプレイヤーが「初めてスポーンした1回目」ならロードを実行
        if (!g_bHasLoadedThisMap[client]) {
            LoadPlayerData(client);
            g_bHasLoadedThisMap[client] = true; // このマップでのロードは完了
        }

        // ロードされた数値を参照し、0.5秒後に武器を自動配布（装備）
        CreateTimer(0.5, Timer_GiveMelee, GetClientUserId(client));
    }
}

public Action Timer_GiveMelee(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2) {
        // 初期状態(none)や空文字ではない、有効な武器がセットされている場合のみ装備させる
        if (g_bAutoEquip[client] && g_szFavoriteMelee[client][0] != '\0' && !StrEqual(g_szFavoriteMelee[client], "none")) {
            ExecuteGiveMelee(client, g_szFavoriteMelee[client]);
        }
    }
    return Plugin_Stop;
}

// ------------------------------------------------------------------
// サブ武器配布ロジック (その子の書いたオリジナルの挙動を100%完全維持)
// ------------------------------------------------------------------
void ExecuteGiveMelee(int client, const char[] weaponName)
{
    int currentMelee = GetPlayerWeaponSlot(client, 1);
    
    // 既存のサブ武器を前方に格好良く投げ捨てる処理
    if (currentMelee != -1 && IsValidEntity(currentMelee)) {
        float eyePos[3], eyeAng[3], vecVelocity[3];
        GetClientEyePosition(client, eyePos);
        GetClientEyeAngles(client, eyeAng);
        GetAngleVectors(eyeAng, vecVelocity, NULL_VECTOR, NULL_VECTOR);
        
        vecVelocity[0] *= 250.0; 
        vecVelocity[1] *= 250.0;
        vecVelocity[2] = 100.0;  
        
        SDKHooks_DropWeapon(client, currentMelee, NULL_VECTOR, NULL_VECTOR);
        TeleportEntity(currentMelee, NULL_VECTOR, NULL_VECTOR, vecVelocity);
    }

    char finalWeaponName[32]; 
    strcopy(finalWeaponName, sizeof(finalWeaponName), weaponName);
    if (StrEqual(weaponName, "melee")) {
        strcopy(finalWeaponName, sizeof(finalWeaponName), g_szMeleeList[GetRandomInt(0, 13)]);
    }

    // giveコマンドをチート制限をすり抜けて実行する処理
    int giveFlags = GetCommandFlags("give"); 
    SetCommandFlags("give", giveFlags & ~FCVAR_CHEAT);
    int oldFlags = GetUserFlagBits(client);
    SetUserFlagBits(client, ADMFLAG_ROOT);

    if (StrEqual(finalWeaponName, "wpistol")) {
        FakeClientCommand(client, "give pistol");
        FakeClientCommand(client, "give pistol");
    } else {
        char command[64]; 
        Format(command, sizeof(command), "give %s", finalWeaponName); 
        FakeClientCommand(client, command);
    }

    SetUserFlagBits(client, oldFlags);
    SetCommandFlags("give", giveFlags);
}

// ------------------------------------------------------------------
// メニューロジック (2次元配列の文字列指定を完璧に修正)
// ------------------------------------------------------------------

public Action Command_MeleeMain(int client, int args)
{
    if (client == 0 || !IsClientInGame(client)) return Plugin_Handled;
    ShowMainMenu(client, g_iLastMenuSelection[client]); return Plugin_Handled;
}

void GetWeaponMenuName(const char[] weaponName, char[] buffer, int maxlen)
{
    if (StrEqual(weaponName, "knife")) strcopy(buffer, maxlen, "Hunting Knife");
    else if (StrEqual(weaponName, "pistol_magnum")) strcopy(buffer, maxlen, "Magnum");
    else if (StrEqual(weaponName, "wpistol")) strcopy(buffer, maxlen, "W Pistol");
    else if (StrEqual(weaponName, "pistol")) strcopy(buffer, maxlen, "Pistol");
    else if (StrEqual(weaponName, "melee")) strcopy(buffer, maxlen, "Random");
    else if (StrEqual(weaponName, "riotshield")) strcopy(buffer, maxlen, "Riot Shield");
    else if (weaponName[0] == '\0' || StrEqual(weaponName, "none")) strcopy(buffer, maxlen, "none"); 
    else strcopy(buffer, maxlen, weaponName);
}

void AddStandardMeleeItems(Menu menu)
{
    menu.AddItem("frying_pan", "Frying Pan"); menu.AddItem("katana", "Katana");
    menu.AddItem("machete", "Machete"); menu.AddItem("fireaxe", "Fireaxe");
    menu.AddItem("crowbar", "Crowbar"); menu.AddItem("baseball_bat", "Baseball Bat");
    menu.AddItem("cricket_bat", "Cricket Bat"); menu.AddItem("electric_guitar", "Guitar");
    menu.AddItem("tonfa", "Tonfa"); menu.AddItem("golfclub", "Golf Club");
    menu.AddItem("shovel", "Shovel"); menu.AddItem("pitchfork", "Pitchfork");
    menu.AddItem("riotshield", "Riot Shield");
}

void ShowMainMenu(int client, int startSelection)
{
    Menu menu = new Menu(MenuHandler_MainMenu); menu.SetTitle("My Favorite SideArms 1.0"); 
    char status[32]; Format(status, sizeof(status), "Set:%s", g_bAutoEquip[client] ? "Enable" : "Disable");
    menu.AddItem("toggle", status);
    char displayName[32]; GetWeaponMenuName(g_szFavoriteMelee[client], displayName, sizeof(displayName));
char current[64]; Format(current, sizeof(current), "SetMelee:%s", displayName); menu.AddItem("weapon_list", current);
menu.AddItem("melee", "Random"); menu.AddItem("pistol", "Pistol"); menu.AddItem("wpistol", "W Pistol");
menu.AddItem("pistol_magnum", "Magnum"); menu.AddItem("knife", "Hunting Knife");
AddStandardMeleeItems(menu);
menu.ExitButton = true; g_iLastMenuSelection[client] = startSelection; menu.DisplayAt(client, startSelection, MENU_TIME_FOREVER);
}
public int MenuHandler_MainMenu(Menu menu, MenuAction action, int client, int itemNum)
{
if (action == MenuAction_Select) {
int currentSelection = menu.Selection; char info[32]; menu.GetItem(itemNum, info, sizeof(info));
if (StrEqual(info, "toggle")) {
g_bAutoEquip[client] = !g_bAutoEquip[client]; SavePlayerData(client); ShowMainMenu(client, currentSelection);
} else if (StrEqual(info, "weapon_list")) {
ShowWeaponMenu(client, currentSelection);
} else {
// お気に入り近接武器をメモリにセットして即保存
strcopy(g_szFavoriteMelee[client], 32, info);
SavePlayerData(client);
if (IsPlayerAlive(client) && GetClientTeam(client) == 2) ExecuteGiveMelee(client, info);
ShowMainMenu(client, currentSelection);
}
} else if (action == MenuAction_End) delete menu;
return 0;
}
void ShowWeaponMenu(int client, int mainMenuSelection)
{
Menu menu = new Menu(MenuHandler_WeaponMenu); menu.SetTitle("Select Favorite SideArms:");
menu.AddItem("none", "none"); menu.AddItem("melee", "Random"); menu.AddItem("pistol", "Pistol");
menu.AddItem("wpistol", "W Pistol"); menu.AddItem("pistol_magnum", "Magnum"); menu.AddItem("knife", "Hunting Knife");
AddStandardMeleeItems(menu);
menu.ExitBackButton = true; g_iLastMenuSelection[client] = mainMenuSelection; menu.Display(client, MENU_TIME_FOREVER);
}
public int MenuHandler_WeaponMenu(Menu menu, MenuAction action, int client, int itemNum)
{
if (action == MenuAction_Select) {
char info[32]; menu.GetItem(itemNum, info, sizeof(info));
if (StrEqual(info, "none")) {
g_szFavoriteMelee[client][0] = '\0'; SavePlayerData(client);
} else {
strcopy(g_szFavoriteMelee[client], 32, info); SavePlayerData(client);
}
ShowMainMenu(client, g_iLastMenuSelection[client]);
} else if (action == MenuAction_Cancel && itemNum == MenuCancel_ExitBack) {
ShowMainMenu(client, g_iLastMenuSelection[client]);
} else if (action == MenuAction_End) delete menu;
return 0;
}
// 保険用のダミーフック
public Action OnTraceAttack(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup) { return Plugin_Continue; }
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype) { return Plugin_Continue; }