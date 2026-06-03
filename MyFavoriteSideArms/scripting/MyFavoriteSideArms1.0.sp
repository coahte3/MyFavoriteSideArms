#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <clientprefs>

// グローバル配列にサイズ「32」をきっちり設定して1.12のエラーを修正
char g_szFavoriteMelee[MAXPLAYERS + 1][32]; 
bool g_bAutoEquip[MAXPLAYERS + 1];
int g_iLastMenuSelection[MAXPLAYERS + 1];

// ガチランダム抽選用の全14種類の正確な内部武器IDリスト
static const char g_szMeleeList[][] = {
    "knife", "frying_pan", "katana", "machete", "fireaxe", "crowbar", 
    "baseball_bat", "cricket_bat", "electric_guitar", "tonfa", "golfclub", 
    "shovel", "pitchfork", "riotshield"
};

public Plugin myinfo = {
    name = "My Favorite SideArms 1.0",
    author = "coah&GoogleAI&BigSister", // 頼れるお姉ちゃんもクレジットに招待！
    description = "Perfect Secondary Weapon Save & Auto-Equip System",
    version = "1.0",
    url = ""
};

public void OnPluginStart()
{
    // コマンドとプレイヤースポーンイベントの登録のみにスッキリ整理しました
    RegConsoleCmd("sm_melee", Command_MeleeMain, "Open SideArms Weapon Menu");
    HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
}

public void OnMapStart()
{
    // ライオットシールドの3Dモデルデータをマップ開始時に強制プリロード（アンロック）
    if (!IsModelPrecached("models/w_models/weapons/w_riotshield.mdl")) {
        PrecacheModel("models/w_models/weapons/w_riotshield.mdl", true);
    }
}

// ファイルシステムで使えない禁止文字を安全なアンダーバーに一括置換する関数
void CleanFileName(char[] buffer, int maxlen)
{
    ReplaceString(buffer, maxlen, ":", "_"); ReplaceString(buffer, maxlen, "/", "_");
    ReplaceString(buffer, maxlen, "\\", "_"); ReplaceString(buffer, maxlen, "*", "_");
    ReplaceString(buffer, maxlen, "?", "_"); ReplaceString(buffer, maxlen, "\"", "_");
    ReplaceString(buffer, maxlen, "<", "_"); ReplaceString(buffer, maxlen, ">", "_");
    ReplaceString(buffer, maxlen, "|", "_");
}

// 【セーブ機能】お姉ちゃん大正解の「専用フォルダ自動作成」を搭載した鉄壁のセーブ
void SavePlayerData(int client)
{
    if (IsFakeClient(client)) return;
    char auth[64]; 
    GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
    
    // もしIDが取れなかったり、エラー文字列だったら名前を使う
    if (StrContains(auth, "STEAM") == -1 || StrContains(auth, "STOP_IGNORING") != -1) {
        GetClientName(client, auth, sizeof(auth));
    }
    
    CleanFileName(auth, sizeof(auth)); // 禁止文字を消す

    char folder[PLATFORM_MAX_PATH]; BuildPath(Path_SM, folder, sizeof(folder), "data/sidearms");
    if (!DirExists(folder)) CreateDirectory(folder, 511); // 専用フォルダがない場合は自動で作成！

    char path[PLATFORM_MAX_PATH]; Format(path, sizeof(path), "%s/%s.txt", folder, auth);
    File file = OpenFile(path, "w");
    if (file != null) {
        file.WriteLine("%s", g_bAutoEquip[client] ? "1" : "0"); 
        file.WriteLine("%s", g_szFavoriteMelee[client]); // ここで配列の [client] を指定
        delete file;
    }
}

// 【ロード機能】保存先と同じ data/sidearms/ フォルダから安全にデータを読み直す
void LoadPlayerData(int client)
{
    g_szFavoriteMelee[client][0] = '\0'; g_bAutoEquip[client] = true;
    if (IsFakeClient(client)) return;
    char auth[64]; GetClientAuthId(client, AuthId_Steam2, auth, sizeof(auth));
    
    if (StrContains(auth, "STEAM") != 0 || StrEqual(auth, "STEAM_ID_LAN") || StrContains(auth, "IGNORE") != -1 || auth[0] == '\0') {
        GetClientName(client, auth, sizeof(auth));
    }
    CleanFileName(auth, sizeof(auth));

    char path[PLATFORM_MAX_PATH]; BuildPath(Path_SM, path, sizeof(path), "data/sidearms/%s.txt", auth);
    if (FileExists(path)) {
        File file = OpenFile(path, "r");
        if (file != null) {
            char line[16]; file.ReadLine(line, sizeof(line)); TrimString(line); g_bAutoEquip[client] = !StrEqual(line, "0");
            file.ReadLine(g_szFavoriteMelee[client], 32); TrimString(g_szFavoriteMelee[client]); delete file;
        }
    }
}

public void OnClientPutInServer(int client)
{
    g_iLastMenuSelection[client] = 0; LoadPlayerData(client);
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2) {
        CreateTimer(0.5, Timer_GiveMelee, GetClientUserId(client));
    }
}

public Action Timer_GiveMelee(Handle timer, int userId)
{
    int client = GetClientOfUserId(userId);
    if (client > 0 && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2) {
        if (g_bAutoEquip[client] && g_szFavoriteMelee[client][0] != '\0') ExecuteGiveMelee(client, g_szFavoriteMelee[client]);
    }
    return Plugin_Stop;
}

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
    else if (StrEqual(weaponName, "melee")) strcopy(buffer, maxlen, "Random");
    else if (StrEqual(weaponName, "riotshield")) strcopy(buffer, maxlen, "Riot Shield");
    else if (weaponName[0] == '\0') strcopy(buffer, maxlen, "none"); 
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

void ExecuteGiveMelee(int client, const char[] weaponName)
{
    // --- 1. 武器を捨てる処理 (視線の方向に飛ばす！) ---
    int currentMelee = GetPlayerWeaponSlot(client, 1);
    
    if (currentMelee != -1 && IsValidEntity(currentMelee)) {
        float eyePos[3], eyeAng[3], vecVelocity[3];
        GetClientEyePosition(client, eyePos);
        GetClientEyeAngles(client, eyeAng);
        GetAngleVectors(eyeAng, vecVelocity, NULL_VECTOR, NULL_VECTOR);
        
        vecVelocity[0] *= 250.0; // 前方向に飛ばす力
        vecVelocity[1] *= 250.0;
        vecVelocity[2] = 100.0;  // 少し上に飛ばす力
        
        SDKHooks_DropWeapon(client, currentMelee, NULL_VECTOR, NULL_VECTOR);
        TeleportEntity(currentMelee, NULL_VECTOR, NULL_VECTOR, vecVelocity);
    }

    // --- 2. 新しい武器を渡す処理 (これが give処理！) ---
    char finalWeaponName[32]; 
    strcopy(finalWeaponName, sizeof(finalWeaponName), weaponName);
    if (StrEqual(weaponName, "melee")) {
        strcopy(finalWeaponName, sizeof(finalWeaponName), g_szMeleeList[GetRandomInt(0, 13)]);
    }

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