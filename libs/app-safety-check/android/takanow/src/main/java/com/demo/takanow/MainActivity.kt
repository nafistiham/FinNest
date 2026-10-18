package com.demo.takanow

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.provider.Settings
import android.text.InputType
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast

/**
 * A loan-form-looking screen with a prominent DEMO banner in English and Bangla.
 * Nothing on this screen reads, stores or sends anything; "Apply" only shows a toast.
 */
class MainActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pad = (16 * resources.displayMetrics.density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        root.addView(TextView(this).apply {
            text = getString(R.string.banner)
            setBackgroundColor(Color.parseColor("#B00020"))
            setTextColor(Color.WHITE)
            textSize = 18f
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setPadding(pad, pad, pad, pad)
        })

        root.addView(TextView(this).apply {
            text = getString(R.string.headline)
            textSize = 22f
            typeface = Typeface.DEFAULT_BOLD
            setPadding(0, pad, 0, pad / 2)
        })

        root.addView(field(R.string.hint_name, InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_WORDS))
        root.addView(field(R.string.hint_phone, InputType.TYPE_CLASS_PHONE))
        root.addView(field(R.string.hint_amount, InputType.TYPE_CLASS_NUMBER))

        root.addView(Button(this).apply {
            text = getString(R.string.btn_apply)
            setOnClickListener {
                Toast.makeText(this@MainActivity, R.string.toast_demo, Toast.LENGTH_LONG).show()
            }
        })

        // Takes the presenter to Settings > Accessibility; on a browser-installed APK on Android 13+
        // the toggle is greyed out until "Allow restricted settings" is granted from App info.
        root.addView(Button(this).apply {
            text = getString(R.string.btn_accessibility)
            setOnClickListener { startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
        })

        root.addView(TextView(this).apply {
            text = getString(R.string.footnote)
            textSize = 13f
            setPadding(0, pad, 0, 0)
        })

        setContentView(root)
    }

    private fun field(hintRes: Int, type: Int): EditText = EditText(this).apply {
        hint = getString(hintRes)
        inputType = type
    }
}
