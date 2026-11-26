package com.cheongilkim.uvccam;

import android.Manifest;
import android.app.AlertDialog;
import android.app.PictureInPictureParams;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.Configuration;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.hardware.usb.UsbDevice;
import android.hardware.usb.UsbInterface;
import android.media.AudioDeviceCallback;
import android.media.AudioDeviceInfo;
import android.media.AudioManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.TextUtils;
import android.util.Rational;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.app.ActivityCompat;
import androidx.core.content.ContextCompat;

import com.herohan.uvcapp.CameraException;
import com.herohan.uvcapp.CameraHelper;
import com.herohan.uvcapp.CameraPreviewConfig;
import com.herohan.uvcapp.ICameraHelper;
import com.serenegiant.opengl.renderer.MirrorMode;
import com.serenegiant.usb.Size;
import com.serenegiant.usb.UVCCamera;
import com.serenegiant.utils.UVCUtils;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends AppCompatActivity implements SurfaceHolder.Callback {

    private static final int REQ_CAMERA_PERMISSION = 1001;
    private static final String PREFS_NAME = "uvccam_prefs";
    private static final String KEY_PRESET = "preset";
    private static final String KEY_ROTATION = "rotation";
    private static final String KEY_MIRRORED = "mirrored";
    private static final String KEY_FILL = "fill_screen";

    private enum Preset {
        READING_1080P_10("1080p 독서·저발열 (10fps)", "1080p 10fps", 1920, 1080, 10),
        UHD_4K("4K 초고화질 (2160p)", "4K 2160p", 3840, 2160, 30),
        FHD_1080P_30("1080p 부드럽게 (30fps)", "1080p 30fps", 1920, 1080, 30),
        HD_720P_30("720p 초저발열 (30fps)", "720p 30fps", 1280, 720, 30);

        final String title;
        final String shortTitle;
        final int width;
        final int height;
        final int fps;

        Preset(String title, String shortTitle, int width, int height, int fps) {
            this.title = title;
            this.shortTitle = shortTitle;
            this.width = width;
            this.height = height;
            this.fps = fps;
        }
    }

    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private SharedPreferences prefs;

    private Preset activePreset = Preset.READING_1080P_10;
    private int rotationDegrees = 0;
    private boolean mirrored = false;
    private boolean fillScreen = false;
    private boolean hudVisible = true;

    private FrameLayout rootLayout;
    private SurfaceView surfaceView;
    private View topHud;
    private View bottomHud;
    private View statusDot;
    private TextView statusTextView;
    private TextView metaTextView;

    private Button cameraBtn;
    private Button presetBtn;
    private Button audioBtn;
    private Button rotateBtn;
    private Button mirrorBtn;
    private Button fitBtn;

    private ICameraHelper cameraHelper;
    private UsbDevice activeDevice;
    private boolean surfaceReady = false;
    private boolean previewStarted = false;
    private int currentCamW = 1920;
    private int currentCamH = 1080;
    private int currentCamFps = 0;

    private AudioManager audioManager;
    private final AudioDeviceCallback audioDeviceCallback = new AudioDeviceCallback() {
        @Override
        public void onAudioDevicesAdded(AudioDeviceInfo[] addedDevices) {
            refreshAudioOutputBadge();
        }

        @Override
        public void onAudioDevicesRemoved(AudioDeviceInfo[] removedDevices) {
            refreshAudioOutputBadge();
        }
    };

    private final ICameraHelper.StateCallback stateCallback = new ICameraHelper.StateCallback() {
        @Override
        public void onAttach(UsbDevice device) {
            if (!isUvcVideoDevice(device)) return;
            refreshCameraButtonLabel();
            setStatus(StatusKind.WARN, "UVC 감지 · 연결 중...");
            if (activeDevice == null || activeDevice.equals(device)) {
                activeDevice = device;
                if (cameraHelper != null) {
                    cameraHelper.selectDevice(device);
                }
            }
        }

        @Override
        public void onDeviceOpen(UsbDevice device, boolean isFirstOpen) {
            activeDevice = device;
            refreshCameraButtonLabel();
            openWithActivePreset();
        }

        @Override
        public void onCameraOpen(UsbDevice device) {
            activeDevice = device;
            applyPreviewConfig();
            if (cameraHelper != null) {
                if (surfaceReady) {
                    cameraHelper.addSurface(surfaceView.getHolder().getSurface(), false);
                }
                cameraHelper.startPreview();
                previewStarted = true;
            }
            Size actual = cameraHelper != null ? cameraHelper.getPreviewSize() : null;
            if (actual != null && actual.width > 0 && actual.height > 0) {
                currentCamW = actual.width;
                currentCamH = actual.height;
                currentCamFps = actual.fps;
            }
            updatePreviewLayout();
            updateMetaBadge();
            setStatus(StatusKind.LIVE, "UVC 연결됨 · " + formatDeviceName(device));
        }

        @Override
        public void onCameraClose(UsbDevice device) {
            previewStarted = false;
            if (surfaceReady && cameraHelper != null) {
                try {
                    cameraHelper.removeSurface(surfaceView.getHolder().getSurface());
                } catch (Exception ignored) {
                }
            }
            setStatus(StatusKind.WARN, "카메라 일시 중지");
        }

        @Override
        public void onDeviceClose(UsbDevice device) {
            previewStarted = false;
            if (device != null && device.equals(activeDevice)) {
                setStatus(StatusKind.WARN, "장치 연결 대기 중...");
            }
        }

        @Override
        public void onDetach(UsbDevice device) {
            if (device != null && device.equals(activeDevice)) {
                previewStarted = false;
                activeDevice = null;
                setStatus(StatusKind.ERROR, "UVC 연결 해제됨 · USB 확인");
                refreshCameraButtonLabel();
                trySelectFirstAvailableDevice();
            }
        }

        @Override
        public void onCancel(UsbDevice device) {
            setStatus(StatusKind.ERROR, "USB 접근 권한이 거부됨");
        }

        @Override
        public void onError(UsbDevice device, CameraException e) {
            setStatus(StatusKind.ERROR, "연결 오류 · 재연결 시도 중...");
            mainHandler.postDelayed(() -> {
                if (!isFinishing() && !isDestroyed()) {
                    reconnectCamera();
                }
            }, 800);
        }
    };

    private enum StatusKind {
        LIVE, WARN, ERROR
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        UVCUtils.init(getApplication());

        prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE);
        loadPreferences();
        buildUi();
        syncControlsUi();

        audioManager = (AudioManager) getSystemService(Context.AUDIO_SERVICE);
        if (audioManager != null) {
            audioManager.registerAudioDeviceCallback(audioDeviceCallback, mainHandler);
        }
        refreshAudioOutputBadge();

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            initCameraHelper();
        } else {
            setStatus(StatusKind.WARN, "카메라 권한 허용 필요");
            ActivityCompat.requestPermissions(this, new String[]{Manifest.permission.CAMERA}, REQ_CAMERA_PERMISSION);
        }
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (cameraHelper != null) {
            trySelectFirstAvailableDevice();
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        applySystemBarsVisibility();
        refreshAudioOutputBadge();
        if (cameraHelper != null && activeDevice != null && !cameraHelper.isCameraOpened()) {
            cameraHelper.selectDevice(activeDevice);
        } else if (cameraHelper != null && activeDevice == null) {
            trySelectFirstAvailableDevice();
        }
    }

    @Override
    public void onConfigurationChanged(@NonNull Configuration newConfig) {
        super.onConfigurationChanged(newConfig);
        mainHandler.post(this::updatePreviewLayout);
    }

    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode, @NonNull Configuration newConfig) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig);
        if (isInPictureInPictureMode) {
            topHud.setVisibility(View.GONE);
            bottomHud.setVisibility(View.GONE);
        } else {
            topHud.setVisibility(hudVisible ? View.VISIBLE : View.GONE);
            bottomHud.setVisibility(hudVisible ? View.VISIBLE : View.GONE);
        }
        mainHandler.post(this::updatePreviewLayout);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, @NonNull String[] permissions, @NonNull int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_CAMERA_PERMISSION) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                initCameraHelper();
            } else {
                setStatus(StatusKind.ERROR, "카메라 권한이 거부되었습니다");
                Toast.makeText(this, "설정에서 UVC Cam 카메라 권한을 허용해 주세요", Toast.LENGTH_LONG).show();
            }
        }
    }

    @Override
    protected void onDestroy() {
        if (audioManager != null) {
            audioManager.unregisterAudioDeviceCallback(audioDeviceCallback);
        }
        if (cameraHelper != null) {
            try {
                cameraHelper.releaseAll();
            } catch (Exception ignored) {
            }
            cameraHelper = null;
        }
        super.onDestroy();
    }

    private void loadPreferences() {
        String presetName = prefs.getString(KEY_PRESET, Preset.READING_1080P_10.name());
        try {
            activePreset = Preset.valueOf(presetName);
        } catch (IllegalArgumentException e) {
            activePreset = Preset.READING_1080P_10;
        }
        int savedRot = prefs.getInt(KEY_ROTATION, 0);
        rotationDegrees = (savedRot == 0 || savedRot == 90 || savedRot == 180 || savedRot == 270) ? savedRot : 0;
        mirrored = prefs.getBoolean(KEY_MIRRORED, false);
        fillScreen = prefs.getBoolean(KEY_FILL, false);
    }

    private void savePreferences() {
        prefs.edit()
                .putString(KEY_PRESET, activePreset.name())
                .putInt(KEY_ROTATION, rotationDegrees)
                .putBoolean(KEY_MIRRORED, mirrored)
                .putBoolean(KEY_FILL, fillScreen)
                .apply();
    }

    private void buildUi() {
        rootLayout = new FrameLayout(this);
        rootLayout.setBackgroundColor(Color.BLACK);
        rootLayout.setOnClickListener(v -> toggleHud());
        rootLayout.addOnLayoutChangeListener((v, left, top, right, bottom, oldL, oldT, oldR, oldB) -> {
            if ((right - left) != (oldR - oldL) || (bottom - top) != (oldB - oldT)) {
                updatePreviewLayout();
            }
        });

        surfaceView = new SurfaceView(this);
        surfaceView.getHolder().addCallback(this);
        FrameLayout.LayoutParams svLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
                Gravity.CENTER
        );
        rootLayout.addView(surfaceView, svLp);

        // Top HUD
        LinearLayout topBar = new LinearLayout(this);
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        int pad = dp(12);
        topBar.setPadding(pad, dp(16), pad, dp(8));

        LinearLayout statusPill = makePillContainer();
        statusDot = new View(this);
        LinearLayout.LayoutParams dotLp = new LinearLayout.LayoutParams(dp(9), dp(9));
        dotLp.rightMargin = dp(8);
        statusPill.addView(statusDot, dotLp);

        statusTextView = new TextView(this);
        statusTextView.setTextColor(Color.WHITE);
        statusTextView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        statusTextView.setSingleLine(true);
        statusTextView.setEllipsize(TextUtils.TruncateAt.END);
        statusTextView.setText("UVC 카메라 검색 중...");
        statusPill.addView(statusTextView);

        LinearLayout.LayoutParams statusPillLp = new LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.WRAP_CONTENT,
                1f
        );
        statusPillLp.rightMargin = dp(8);
        topBar.addView(statusPill, statusPillLp);

        LinearLayout metaPill = makePillContainer();
        metaTextView = new TextView(this);
        metaTextView.setTextColor(Color.argb(200, 245, 247, 250));
        metaTextView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        metaTextView.setSingleLine(true);
        metaTextView.setText("대기");
        metaPill.addView(metaTextView);
        topBar.addView(metaPill);

        topHud = topBar;
        FrameLayout.LayoutParams topLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.TOP
        );
        rootLayout.addView(topHud, topLp);

        // Bottom HUD
        FrameLayout bottomWrap = new FrameLayout(this);
        bottomWrap.setPadding(pad, dp(8), pad, dp(16));

        HorizontalScrollView scroll = new HorizontalScrollView(this);
        scroll.setHorizontalScrollBarEnabled(false);
        scroll.setBackground(makeRoundedBg(Color.argb(190, 16, 18, 22), Color.argb(45, 255, 255, 255), 20));
        scroll.setPadding(dp(8), dp(8), dp(8), dp(8));

        LinearLayout bar = new LinearLayout(this);
        bar.setOrientation(LinearLayout.HORIZONTAL);
        bar.setGravity(Gravity.CENTER_VERTICAL);

        cameraBtn = makeHudButton("카메라", v -> showCameraChooser());
        presetBtn = makeHudButton(activePreset.shortTitle, v -> showPresetChooser());
        audioBtn = makeHudButton("오디오 출력", v -> openAudioOutputPanel());
        rotateBtn = makeHudButton("회전 0°", v -> {
            rotationDegrees = (rotationDegrees + 90) % 360;
            savePreferences();
            syncControlsUi();
            applyPreviewConfig();
            updatePreviewLayout();
            updateMetaBadge();
            Toast.makeText(this, "화면 회전 " + rotationDegrees + "°", Toast.LENGTH_SHORT).show();
        });
        mirrorBtn = makeHudButton("좌우반전", v -> {
            mirrored = !mirrored;
            savePreferences();
            syncControlsUi();
            applyPreviewConfig();
            Toast.makeText(this, mirrored ? "좌우 반전 켜짐" : "좌우 반전 꺼짐", Toast.LENGTH_SHORT).show();
        });
        fitBtn = makeHudButton("전체보기", v -> {
            fillScreen = !fillScreen;
            savePreferences();
            syncControlsUi();
            updatePreviewLayout();
            Toast.makeText(this, fillScreen ? "꽉 채우기 (Cover)" : "전체 보기 (Contain)", Toast.LENGTH_SHORT).show();
        });
        Button pipBtn = makeHudButton("PIP", v -> enterPipMode());
        Button reconnectBtn = makeHudButton("재연결", v -> reconnectCamera());
        styleHudButton(reconnectBtn, true, true);

        addControlWithGap(bar, cameraBtn, true);
        addControlWithGap(bar, presetBtn, true);
        addControlWithGap(bar, audioBtn, true);
        addControlWithGap(bar, rotateBtn, true);
        addControlWithGap(bar, mirrorBtn, true);
        addControlWithGap(bar, fitBtn, true);
        addControlWithGap(bar, pipBtn, true);
        addControlWithGap(bar, reconnectBtn, false);

        scroll.addView(bar);
        bottomWrap.addView(scroll, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.CENTER_HORIZONTAL
        ));

        bottomHud = bottomWrap;
        FrameLayout.LayoutParams bottomLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM
        );
        rootLayout.addView(bottomHud, bottomLp);

        setContentView(rootLayout);
        setStatus(StatusKind.WARN, "UVC 카메라 검색 중...");
    }

    private void addControlWithGap(LinearLayout parent, View child, boolean withMargin) {
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
        );
        if (withMargin) {
            lp.rightMargin = dp(8);
        }
        parent.addView(child, lp);
    }

    private LinearLayout makePillContainer() {
        LinearLayout ll = new LinearLayout(this);
        ll.setOrientation(LinearLayout.HORIZONTAL);
        ll.setGravity(Gravity.CENTER_VERTICAL);
        ll.setBackground(makeRoundedBg(Color.argb(190, 16, 18, 22), Color.argb(45, 255, 255, 255), 999));
        ll.setPadding(dp(12), dp(7), dp(12), dp(7));
        ll.setClickable(true);
        return ll;
    }

    private Button makeHudButton(String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setAllCaps(false);
        b.setText(text);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        b.setPadding(dp(12), dp(6), dp(12), dp(6));
        b.setMinHeight(dp(36));
        b.setMinimumHeight(dp(36));
        b.setMinWidth(0);
        b.setMinimumWidth(0);
        b.setOnClickListener(listener);
        styleHudButton(b, false, false);
        return b;
    }

    private void styleHudButton(Button b, boolean active, boolean primary) {
        int bg;
        int stroke;
        int textColor;
        if (primary) {
            bg = Color.argb(110, 10, 132, 255);
            stroke = Color.argb(190, 10, 132, 255);
            textColor = Color.WHITE;
        } else if (active) {
            bg = Color.argb(85, 50, 215, 75);
            stroke = Color.argb(180, 50, 215, 75);
            textColor = Color.rgb(216, 255, 224);
        } else {
            bg = Color.argb(36, 255, 255, 255);
            stroke = Color.argb(48, 255, 255, 255);
            textColor = Color.WHITE;
        }
        b.setTextColor(textColor);
        b.setBackground(makeRoundedBg(bg, stroke, 12));
    }

    private GradientDrawable makeRoundedBg(int fillColor, int strokeColor, int radiusDp) {
        GradientDrawable gd = new GradientDrawable();
        gd.setColor(fillColor);
        gd.setStroke(dp(1), strokeColor);
        gd.setCornerRadius(dp(radiusDp));
        return gd;
    }

    private void syncControlsUi() {
        presetBtn.setText(activePreset.shortTitle);
        rotateBtn.setText("회전 " + rotationDegrees + "°");
        styleHudButton(rotateBtn, rotationDegrees != 0, false);
        styleHudButton(mirrorBtn, mirrored, false);
        fitBtn.setText(fillScreen ? "꽉채우기" : "전체보기");
        styleHudButton(fitBtn, fillScreen, false);
        refreshCameraButtonLabel();
    }

    private void toggleHud() {
        hudVisible = !hudVisible;
        topHud.setVisibility(hudVisible ? View.VISIBLE : View.GONE);
        bottomHud.setVisibility(hudVisible ? View.VISIBLE : View.GONE);
        applySystemBarsVisibility();
    }

    private void applySystemBarsVisibility() {
        View decor = getWindow().getDecorView();
        if (hudVisible) {
            decor.setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        } else {
            decor.setSystemUiVisibility(
                    View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                            | View.SYSTEM_UI_FLAG_FULLSCREEN
                            | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                            | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                            | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
            );
        }
    }

    private void initCameraHelper() {
        if (cameraHelper != null) return;
        cameraHelper = new CameraHelper();
        cameraHelper.setStateCallback(stateCallback);
        applyPreviewConfig();
        trySelectFirstAvailableDevice();
    }

    private List<UsbDevice> getUvcDevices() {
        List<UsbDevice> result = new ArrayList<>();
        if (cameraHelper == null) return result;
        List<UsbDevice> all = cameraHelper.getDeviceList();
        if (all == null) return result;
        for (UsbDevice d : all) {
            if (isUvcVideoDevice(d)) {
                result.add(d);
            }
        }
        return result;
    }

    private boolean isUvcVideoDevice(UsbDevice device) {
        if (device == null) return false;
        if (device.getDeviceClass() == 14) return true;
        for (int i = 0; i < device.getInterfaceCount(); i++) {
            UsbInterface intf = device.getInterface(i);
            if (intf != null && intf.getInterfaceClass() == 14) {
                return true;
            }
        }
        return false;
    }

    private void trySelectFirstAvailableDevice() {
        List<UsbDevice> uvcList = getUvcDevices();
        refreshCameraButtonLabel();
        if (uvcList.isEmpty()) {
            setStatus(StatusKind.WARN, "UVC 카메라를 USB-C로 연결해 주세요");
            return;
        }
        activeDevice = uvcList.get(0);
        setStatus(StatusKind.WARN, "UVC 연결 중 · " + formatDeviceName(activeDevice));
        cameraHelper.selectDevice(activeDevice);
    }

    private void reconnectCamera() {
        Toast.makeText(this, "UVC 카메라 재검색 중...", Toast.LENGTH_SHORT).show();
        if (cameraHelper == null) {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                initCameraHelper();
            }
            return;
        }
        try {
            if (cameraHelper.isCameraOpened()) {
                cameraHelper.closeCamera();
            }
        } catch (Exception ignored) {
        }
        activeDevice = null;
        mainHandler.postDelayed(this::trySelectFirstAvailableDevice, 250);
    }

    private void openWithActivePreset() {
        if (cameraHelper == null) return;
        List<Size> sizes = cameraHelper.getSupportedSizeList();
        Size best = pickBestSize(sizes, activePreset);
        if (best != null) {
            cameraHelper.openCamera(best);
        } else {
            cameraHelper.openCamera();
        }
    }

    private Size pickBestSize(List<Size> sizes, Preset preset) {
        if (sizes == null || sizes.isEmpty()) return null;
        Size best = null;
        long bestScore = Long.MAX_VALUE;
        for (Size s : sizes) {
            long dist = Math.abs((long) s.width - preset.width) * 4L + Math.abs((long) s.height - preset.height) * 4L;
            long fmtPenalty = (s.type == UVCCamera.FRAME_FORMAT_MJPEG) ? 0L : 50000L;
            long score = dist + fmtPenalty;
            if (score < bestScore) {
                bestScore = score;
                best = s;
            }
        }
        if (best == null) return null;
        Size chosen = best.clone();
        if (chosen.fpsList != null && !chosen.fpsList.isEmpty()) {
            int closestFps = chosen.fps;
            int minDiff = Integer.MAX_VALUE;
            for (Integer f : chosen.fpsList) {
                if (f == null || f <= 0) continue;
                int diff = Math.abs(f - preset.fps);
                if (diff < minDiff) {
                    minDiff = diff;
                    closestFps = f;
                }
            }
            chosen.fps = closestFps;
        }
        return chosen;
    }

    private void applyPreviewConfig() {
        if (cameraHelper == null) return;
        CameraPreviewConfig cfg = cameraHelper.getPreviewConfig();
        cfg.setRotation(rotationDegrees);
        cfg.setMirror(mirrored ? MirrorMode.MIRROR_HORIZONTAL : MirrorMode.MIRROR_NORMAL);
        cameraHelper.setPreviewConfig(cfg);
    }

    private void updatePreviewLayout() {
        int stageW = rootLayout.getWidth();
        int stageH = rootLayout.getHeight();
        if (stageW <= 0 || stageH <= 0) return;

        boolean quarterTurn = (rotationDegrees == 90 || rotationDegrees == 270);
        int effW = quarterTurn ? currentCamH : currentCamW;
        int effH = quarterTurn ? currentCamW : currentCamH;
        if (effW <= 0 || effH <= 0) return;

        double scale = fillScreen
                ? Math.max((double) stageW / effW, (double) stageH / effH)
                : Math.min((double) stageW / effW, (double) stageH / effH);

        int drawW = Math.max(1, (int) Math.round(effW * scale));
        int drawH = Math.max(1, (int) Math.round(effH * scale));

        FrameLayout.LayoutParams lp = (FrameLayout.LayoutParams) surfaceView.getLayoutParams();
        if (lp.width != drawW || lp.height != drawH) {
            lp.width = drawW;
            lp.height = drawH;
            lp.gravity = Gravity.CENTER;
            surfaceView.setLayoutParams(lp);
        }
    }

    private void showCameraChooser() {
        List<UsbDevice> list = getUvcDevices();
        if (list.isEmpty()) {
            Toast.makeText(this, "연결된 USB UVC 카메라가 없습니다", Toast.LENGTH_SHORT).show();
            return;
        }
        String[] labels = new String[list.size()];
        for (int i = 0; i < list.size(); i++) {
            labels[i] = "[UVC] " + formatDeviceName(list.get(i));
        }
        new AlertDialog.Builder(this)
                .setTitle("UVC 카메라 선택")
                .setItems(labels, (dialog, which) -> {
                    activeDevice = list.get(which);
                    cameraHelper.selectDevice(activeDevice);
                })
                .show();
    }

    private void showPresetChooser() {
        Preset[] presets = Preset.values();
        String[] labels = new String[presets.length];
        int checked = 0;
        for (int i = 0; i < presets.length; i++) {
            labels[i] = presets[i].title;
            if (presets[i] == activePreset) checked = i;
        }
        new AlertDialog.Builder(this)
                .setTitle("해상도 · 저발열 프리셋")
                .setSingleChoiceItems(labels, checked, (dialog, which) -> {
                    dialog.dismiss();
                    Preset chosen = presets[which];
                    if (chosen != activePreset) {
                        activePreset = chosen;
                        savePreferences();
                        syncControlsUi();
                        Toast.makeText(this, "화질 설정: " + chosen.shortTitle, Toast.LENGTH_SHORT).show();
                        if (cameraHelper != null && activeDevice != null) {
                            try {
                                cameraHelper.closeCamera();
                            } catch (Exception ignored) {
                            }
                            mainHandler.postDelayed(() -> {
                                if (cameraHelper != null && activeDevice != null) {
                                    cameraHelper.selectDevice(activeDevice);
                                }
                            }, 200);
                        }
                    }
                })
                .show();
    }

    private void refreshAudioOutputBadge() {
        if (audioManager == null) return;
        AudioDeviceInfo[] outputs = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS);
        String btName = null;
        String wiredName = null;
        for (AudioDeviceInfo info : outputs) {
            int type = info.getType();
            CharSequence prod = info.getProductName();
            String label = !TextUtils.isEmpty(prod) ? prod.toString() : "블루투스";
            if (type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP
                    || type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
                    || (Build.VERSION.SDK_INT >= 31 && type == AudioDeviceInfo.TYPE_BLE_HEADSET)) {
                btName = label;
                break;
            }
            if (type == AudioDeviceInfo.TYPE_USB_HEADSET || type == AudioDeviceInfo.TYPE_WIRED_HEADSET) {
                wiredName = label;
            }
        }
        if (btName != null) {
            audioBtn.setText("BT · " + btName);
            styleHudButton(audioBtn, true, false);
        } else if (wiredName != null) {
            audioBtn.setText(wiredName);
            styleHudButton(audioBtn, true, false);
        } else {
            audioBtn.setText("폰 스피커");
            styleHudButton(audioBtn, false, false);
        }
    }

    private void openAudioOutputPanel() {
        String[] options = new String[]{
                "미디어 출력(스피커/블루투스) 패널 열기",
                "블루투스 이어폰 연결 설정 열기"
        };
        new AlertDialog.Builder(this)
                .setTitle("스피커 · 블루투스 출력 (Gemini 호환)")
                .setItems(options, (dialog, which) -> {
                    if (which == 0) {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            try {
                                startActivity(new Intent(Settings.Panel.ACTION_VOLUME));
                                return;
                            } catch (Exception ignored) {
                            }
                        }
                    }
                    try {
                        startActivity(new Intent(Settings.ACTION_BLUETOOTH_SETTINGS));
                    } catch (Exception e) {
                        Toast.makeText(this, "설정 화면을 열 수 없습니다", Toast.LENGTH_SHORT).show();
                    }
                })
                .show();
    }

    private void enterPipMode() {
        boolean quarterTurn = (rotationDegrees == 90 || rotationDegrees == 270);
        int effW = Math.max(1, quarterTurn ? currentCamH : currentCamW);
        int effH = Math.max(1, quarterTurn ? currentCamW : currentCamH);
        try {
            PictureInPictureParams params = new PictureInPictureParams.Builder()
                    .setAspectRatio(new Rational(effW, effH))
                    .build();
            enterPictureInPictureMode(params);
        } catch (Exception e) {
            Toast.makeText(this, "이 화면에서는 분할 화면을 이용해 주세요", Toast.LENGTH_SHORT).show();
        }
    }

    private void refreshCameraButtonLabel() {
        if (activeDevice != null) {
            cameraBtn.setText(formatDeviceName(activeDevice));
        } else {
            cameraBtn.setText("카메라");
        }
    }

    private String formatDeviceName(UsbDevice device) {
        if (device == null) return "UVC 카메라";
        String prod = device.getProductName();
        if (!TextUtils.isEmpty(prod)) return prod.trim();
        return "USB 카메라";
    }

    private void setStatus(StatusKind kind, String message) {
        mainHandler.post(() -> {
            int color;
            switch (kind) {
                case LIVE:
                    color = Color.rgb(50, 215, 75);
                    break;
                case ERROR:
                    color = Color.rgb(255, 69, 58);
                    break;
                default:
                    color = Color.rgb(255, 214, 10);
                    break;
            }
            GradientDrawable dotBg = new GradientDrawable();
            dotBg.setShape(GradientDrawable.OVAL);
            dotBg.setColor(color);
            statusDot.setBackground(dotBg);
            statusTextView.setText(message);
        });
    }

    private void updateMetaBadge() {
        mainHandler.post(() -> {
            if (currentCamW > 0 && currentCamH > 0) {
                String fpsPart = currentCamFps > 0 ? " · " + currentCamFps + "fps" : "";
                metaTextView.setText(currentCamW + "×" + currentCamH + fpsPart + " · " + rotationDegrees + "°");
            } else {
                metaTextView.setText("회전 " + rotationDegrees + "°");
            }
        });
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void surfaceCreated(@NonNull SurfaceHolder holder) {
        surfaceReady = true;
        if (cameraHelper != null && cameraHelper.isCameraOpened()) {
            cameraHelper.addSurface(holder.getSurface(), false);
            if (!previewStarted) {
                cameraHelper.startPreview();
                previewStarted = true;
            }
        }
    }

    @Override
    public void surfaceChanged(@NonNull SurfaceHolder holder, int format, int width, int height) {
    }

    @Override
    public void surfaceDestroyed(@NonNull SurfaceHolder holder) {
        surfaceReady = false;
        if (cameraHelper != null) {
            try {
                cameraHelper.removeSurface(holder.getSurface());
            } catch (Exception ignored) {
            }
        }
    }
}
