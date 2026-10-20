package dev.mbjfw.appliance;
import android.app.Activity;
import android.app.ActivityOptions;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.UserManager;
import android.provider.Settings;
import android.view.WindowManager;
import android.widget.TextView;

// This HOME exists only to recover the game after boot, Home, or an app crash.
// It does not replace Android services needed for permissions, sign-in and saves.
public final class HomeActivity extends Activity {
    private static final int GAME_REQUEST=1;
    private final Handler handler=new Handler(Looper.getMainLooper());
    private final Runnable retry=new Runnable() { public void run() { openGameWhenReady(); } };
    private boolean policyConfigured=false;
    private boolean launchInProgress=false;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        getWindow().getDecorView().setSystemUiVisibility(5894);
        TextView label=new TextView(this);
        label.setText("Starting game…"); label.setGravity(17); setContentView(label);
    }
    @Override public void onNewIntent(Intent intent) { super.onNewIntent(intent); setIntent(intent); launchInProgress=false; openGameWhenReady(); }
    @Override public void onResume() { super.onResume(); openGameWhenReady(); }
    @Override public void onPause() { handler.removeCallbacks(retry); super.onPause(); }
    @Override protected void onActivityResult(int requestCode,int resultCode,Intent data) {
        super.onActivityResult(requestCode,resultCode,data);
        if (requestCode==GAME_REQUEST) { launchInProgress=false; retryLater(); }
    }
    private void openGameWhenReady() {
        if (!((UserManager)getSystemService(USER_SERVICE)).isUserUnlocked()) { retryLater(); return; }
        DevicePolicyManager policy=getSystemService(DevicePolicyManager.class);
        if (policy.isDeviceOwnerApp(getPackageName())) {
            ComponentName admin=new ComponentName(this,AdminReceiver.class);
            if (!policy.isAdminActive(admin)) { retryLater(); return; }
            if (!policyConfigured) {
                try {
                    policy.setLockTaskPackages(admin,new String[]{getPackageName(),"com.mojang.minecraftpe","com.android.chrome"});
                    policy.setLockTaskFeatures(admin,DevicePolicyManager.LOCK_TASK_FEATURE_NONE);
                    policy.setStatusBarDisabled(admin,true);
                    policy.setKeyguardDisabled(admin,true);
                    IntentFilter home=new IntentFilter(Intent.ACTION_MAIN);
                    home.addCategory(Intent.CATEGORY_HOME); home.addCategory(Intent.CATEGORY_DEFAULT);
                    policy.addPersistentPreferredActivity(admin,home,new ComponentName(this,HomeActivity.class));
                    policyConfigured=true;
                } catch (RuntimeException transientPolicyFailure) {
                    retryLater(); return;
                }
            }
        }
        int boot=Settings.Global.getInt(getContentResolver(),Settings.Global.BOOT_COUNT,-1);
        android.content.SharedPreferences state=getSharedPreferences("session",MODE_PRIVATE);
        if (getIntent().getBooleanExtra("hostReady",false) && boot>=0) {
            state.edit().putInt("readyBoot",boot).commit();
            getIntent().removeExtra("hostReady");
        }
        // The host attaches HID and configures display/wake state before opening
        // the game. Recovery during this same boot remains automatic.
        if (boot<0 || state.getInt("readyBoot",-2)!=boot) return;
        if (launchInProgress) return;
        Intent game=getPackageManager().getLaunchIntentForPackage("com.mojang.minecraftpe");
        if (game!=null) {
            game.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
            ActivityOptions options=ActivityOptions.makeBasic();
            if (policy.isDeviceOwnerApp(getPackageName()) && policy.isLockTaskPermitted("com.mojang.minecraftpe")) options.setLockTaskEnabled(true);
            try { launchInProgress=true; startActivityForResult(game,GAME_REQUEST,options.toBundle()); return; } catch (RuntimeException ignored) { launchInProgress=false; }
        }
        retryLater();
    }
    private void retryLater() { handler.removeCallbacks(retry); handler.postDelayed(retry,500); }
}
