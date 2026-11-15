package dev.e2estudio.sdk;

import android.app.Application;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;

/** Manifest-merged test-build entry point; it never opens a listener without Studio launch arguments. */
public final class SdkProvider extends ContentProvider {
    public boolean onCreate() {
        if (getContext().getApplicationContext() instanceof Application)
            E2EStudioSdk.install((Application)getContext().getApplicationContext());
        return true;
    }
    public Cursor query(Uri u,String[] p,String s,String[] a,String o) { return null; }
    public String getType(Uri u) { return null; }
    public Uri insert(Uri u, ContentValues v) { return null; }
    public int delete(Uri u,String s,String[] a) { return 0; }
    public int update(Uri u,ContentValues v,String s,String[] a) { return 0; }
}
