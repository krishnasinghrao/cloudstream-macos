package androidx.fragment.app

/*
 * Inert Android UI base types (plan RT-13/RT-15). Extensions construct their
 * settings screens in load() and hand them to openSettings, which the Mac app
 * never invokes (no Android UI is rendered). The types exist so those classes
 * link and construct; their UI behaviour is absent by design, and the
 * extension row reports "Android settings screens" as unavailable.
 */

open class Fragment

open class DialogFragment : Fragment()

open class FragmentManager

open class FragmentActivity : android.app.Activity()
