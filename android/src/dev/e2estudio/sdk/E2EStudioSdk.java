package dev.e2estudio.sdk;

import android.app.*;
import android.content.pm.ApplicationInfo;
import android.graphics.Rect;
import android.os.*;
import android.view.*;
import android.view.inputmethod.*;
import android.widget.*;
import org.json.*;
import java.io.*;
import java.lang.ref.WeakReference;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.concurrent.*;

/** Native Android Views test SDK. No root, patched APK, accessibility service, or private Android API. */
public final class E2EStudioSdk implements Application.ActivityLifecycleCallbacks {
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static E2EStudioSdk instance;
    private final Application app;
    private volatile WeakReference<Activity> current = new WeakReference<>(null);
    private volatile String token;
    private volatile ServerSocket server;
    private E2EStudioSdk(Application app) { this.app = app; }

    public static synchronized void install(Application app) {
        if (instance != null || (app.getApplicationInfo().flags & ApplicationInfo.FLAG_DEBUGGABLE) == 0) return;
        instance = new E2EStudioSdk(app);
        app.registerActivityLifecycleCallbacks(instance);
    }
    public void onActivityCreated(Activity a,Bundle b) {
        current = new WeakReference<>(a);
        String t = a.getIntent().getStringExtra("e2e.sdk.token");
        int port = a.getIntent().getIntExtra("e2e.sdk.port",0);
        if (t != null && t.length() >= 32 && port >= 1024 && port <= 65535 && server == null) start(port,t);
    }
    public void onActivityResumed(Activity a) { current = new WeakReference<>(a); }
    public void onActivityPaused(Activity a) {}
    public void onActivityStarted(Activity a) {}
    public void onActivityStopped(Activity a) {}
    public void onActivitySaveInstanceState(Activity a,Bundle b) {}
    public void onActivityDestroyed(Activity a) { if (current.get() == a) current = new WeakReference<>(null); }

    private void start(final int port,final String t) {
        token = t;
        Thread thread = new Thread(new Runnable() { public void run() {
            try (ServerSocket listener = new ServerSocket()) {
                listener.bind(new InetSocketAddress("127.0.0.1",port)); server = listener;
                while (!listener.isClosed()) {
                    try (Socket socket = listener.accept()) { socket.setSoTimeout(5000); serve(socket); }
                    catch (Exception ignored) { /* A lost client cannot stop the test app. */ }
                }
            } catch (IOException ignored) { /* Discovery reports unavailable; ordinary app startup continues. */ }
            finally { server = null; }
        } },"E2EStudioSDK");
        thread.setDaemon(true); thread.start();
    }
    private static String line(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int c;
        while ((c=in.read()) != -1) { if(c=='\n') break; if(c!='\r')b.write(c); if(b.size()>8192)throw new IOException("header too large"); }
        return b.toString("UTF-8");
    }
    private void serve(Socket socket) throws Exception {
        InputStream in = new BufferedInputStream(socket.getInputStream());
        String[] first = line(in).split(" ");
        if(first.length<2)return;
        String auth=""; int size=0; int headers=0;
        for(String h;(h=line(in)).length()>0;) {
            if(++headers>32)throw new IOException("too many headers");
            int colon=h.indexOf(':'); if(colon<0)continue;
            String key=h.substring(0,colon).trim(),value=h.substring(colon+1).trim();
            if(key.equalsIgnoreCase("Authorization"))auth=value;
            if(key.equalsIgnoreCase("Content-Length"))size=Integer.parseInt(value);
        }
        if(!MessageDigest.isEqual(auth.getBytes(StandardCharsets.UTF_8),("Bearer "+token).getBytes(StandardCharsets.UTF_8))) {
            respond(socket,401,new JSONObject().put("error","Unauthorized"));return;
        }
        if(size<0||size>1048576) { respond(socket,413,new JSONObject().put("error","Request too large"));return; }
        byte[] bytes=new byte[size];int read=0;
        while(read<size){int n=in.read(bytes,read,size-read);if(n<0)throw new EOFException();read+=n;}
        JSONObject body=size==0?new JSONObject():new JSONObject(new String(bytes,StandardCharsets.UTF_8));
        try {
            final String method=first[0],path=first[1];
            Object value=onMain(new Callable<Object>() { public Object call() throws Exception { return handle(method,path,body); } });
            respond(socket,200,new JSONObject().put("value",value));
        } catch(Exception e) { respond(socket,422,new JSONObject().put("error",e.getMessage()==null?"SDK operation failed":e.getMessage())
            .put("code",e.getMessage()!=null&&e.getMessage().startsWith("NOT_FOREGROUND")?"NOT_FOREGROUND":e.getMessage()!=null&&e.getMessage().startsWith("UNSUPPORTED_UI")?"UNSUPPORTED_UI":"OPERATION_FAILED")); }
    }
    private static void respond(Socket socket,int status,JSONObject body) throws IOException {
        byte[] bytes=body.toString().getBytes(StandardCharsets.UTF_8);
        OutputStream out=socket.getOutputStream();
        out.write(("HTTP/1.1 "+status+" Result\r\nContent-Type: application/json\r\nContent-Length: "+bytes.length+"\r\nConnection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
        out.write(bytes);out.flush();
    }
    private static Object onMain(Callable<Object> work) throws Exception {
        FutureTask<Object> task=new FutureTask<>(work);MAIN.post(task);
        try { return task.get(3,TimeUnit.SECONDS); }
        catch(ExecutionException e) { throw new Exception(e.getCause().getMessage()); }
        catch(TimeoutException e) { task.cancel(false);throw new Exception("UI thread did not respond; action is not retried"); }
    }
    private View root() throws Exception {
        Activity activity=current.get();
        if(activity==null||activity.isFinishing()||!activity.hasWindowFocus())throw new Exception("NOT_FOREGROUND: Application is not the focused foreground window");
        return activity.getWindow().getDecorView();
    }
    private Object handle(String method,String path,JSONObject body) throws Exception {
        if(method.equals("GET")&&path.equals("/status")) {
            Activity a=current.get();View v=a==null?null:a.getWindow().getDecorView();
            boolean nativeViews=v!=null&&!hasCompose(v);
            JSONArray caps=nativeViews?new JSONArray(new String[]{"hierarchy","tap","type","clear","keyboard-hide"}):new JSONArray();
            return new JSONObject().put("product","e2e-studio-inapp-sdk").put("protocol",1).put("version","0.3.2")
                .put("platform","android").put("appId",app.getPackageName()).put("capabilities",caps).put("ready",a!=null&&a.hasWindowFocus());
        }
        View root=root();
        if(hasCompose(root))throw new Exception("UNSUPPORTED_UI: Compose/WebView requires System Driver in SDK 0.1");
        if(method.equals("GET")&&path.equals("/hierarchy"))return new JSONObject().put("root",node(root,0))
            .put("screenSize",new JSONObject().put("width",root.getResources().getDisplayMetrics().widthPixels).put("height",root.getResources().getDisplayMetrics().heightPixels));
        if(!method.equals("POST"))throw new Exception("Unsupported SDK operation");
        if(path.equals("/tap")) {
            int x=body.getInt("x"),y=body.getInt("y");Rect visible=new Rect();
            if(!root.getGlobalVisibleRect(visible)||!visible.contains(x,y))throw new Exception("Tap is outside the visible app window");
            int[] origin=new int[2];root.getLocationOnScreen(origin);long now=SystemClock.uptimeMillis();
            MotionEvent down=MotionEvent.obtain(now,now,MotionEvent.ACTION_DOWN,x-origin[0],y-origin[1],0);
            MotionEvent up=MotionEvent.obtain(now,now+16,MotionEvent.ACTION_UP,x-origin[0],y-origin[1],0);
            boolean handled;
            try { handled=root.dispatchTouchEvent(down);root.dispatchTouchEvent(up); } finally { down.recycle();up.recycle(); }
            if(!handled)throw new Exception("No app view handled the touch");
        } else if(path.equals("/type")||path.equals("/clear")) {
            View focus=root.findFocus();if(!(focus instanceof EditText))throw new Exception("Focus an editable native text field first");
            EditText edit=(EditText)focus;InputConnection connection=edit.onCreateInputConnection(new EditorInfo());
            if(connection==null)throw new Exception("Text field has no input connection");
            if(path.equals("/clear"))connection.setSelection(0,edit.length());
            if(!connection.commitText(path.equals("/clear")?"":body.getString("text"),1))throw new Exception("Text field rejected input");
        } else if(path.equals("/keyboard-hide")) {
            ((InputMethodManager)app.getSystemService("input_method")).hideSoftInputFromWindow(root.getWindowToken(),0);
        } else throw new Exception("Unsupported SDK operation");
        return true;
    }
    private static boolean hasCompose(View v) {
        if(v.getClass().getName().startsWith("androidx.compose.")||v instanceof android.webkit.WebView)return true;
        if(v instanceof ViewGroup)for(int i=0;i<((ViewGroup)v).getChildCount();i++)if(hasCompose(((ViewGroup)v).getChildAt(i)))return true;
        return false;
    }
    private JSONObject node(View v,int depth) throws Exception {
        int[] xy=new int[2];v.getLocationOnScreen(xy);Rect visible=new Rect();
        boolean shown=v.isShown()&&v.getGlobalVisibleRect(visible);
        JSONObject out=new JSONObject().put("className",v.getClass().getName()).put("enabled",v.isEnabled())
            .put("clickable",v.isClickable()).put("focused",v.isFocused()).put("visible",shown)
            .put("bounds",new JSONObject().put("left",shown?visible.left:xy[0]).put("top",shown?visible.top:xy[1]).put("right",shown?visible.right:xy[0]+v.getWidth()).put("bottom",shown?visible.bottom:xy[1]+v.getHeight()));
        if(v.getId()!=View.NO_ID)try{out.put("id",v.getResources().getResourceName(v.getId()));}catch(Exception ignored){}
        if(v.getContentDescription()!=null)out.put("label",v.getContentDescription().toString());
        boolean secure = v instanceof TextView && (((TextView)v).getTransformationMethod() instanceof android.text.method.PasswordTransformationMethod
            || ((((TextView)v).getInputType() & android.text.InputType.TYPE_MASK_VARIATION) == android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD)
            || ((((TextView)v).getInputType() & android.text.InputType.TYPE_MASK_VARIATION) == android.text.InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD)
            || ((((TextView)v).getInputType() & android.text.InputType.TYPE_MASK_CLASS) == android.text.InputType.TYPE_CLASS_NUMBER
                && (((TextView)v).getInputType() & android.text.InputType.TYPE_MASK_VARIATION) == android.text.InputType.TYPE_NUMBER_VARIATION_PASSWORD));
        if(v instanceof TextView)out.put("text",secure?"":((TextView)v).getText().toString());
        if(v instanceof EditText){out.put("value",secure?"":((EditText)v).getText().toString());if(((EditText)v).getHint()!=null)out.put("hint",((EditText)v).getHint().toString());}
        if(v instanceof Checkable)out.put("checked",((Checkable)v).isChecked());
        JSONArray children=new JSONArray();
        if(v instanceof ViewGroup&&depth<60)for(int i=0;i<((ViewGroup)v).getChildCount();i++)children.put(node(((ViewGroup)v).getChildAt(i),depth+1));
        return out.put("children",children);
    }
}
