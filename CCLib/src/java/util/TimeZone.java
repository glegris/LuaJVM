/**************************************************************************
 * Parts copyright (c) 2001 by Punch Telematix. All rights reserved.       *
 * Parts copyright (c) 2004, 2008, 2009 by Chris Gray, /k/ Embedded Java   *
 * Solutions.  All rights reserved.                                        *
 *                                                                         *
 * Redistribution and use in source and binary forms, with or without      *
 * modification, are permitted provided that the following conditions      *
 * are met:                                                                *
 * 1. Redistributions of source code must retain the above copyright       *
 *    notice, this list of conditions and the following disclaimer.        *
 * 2. Redistributions in binary form must reproduce the above copyright    *
 *    notice, this list of conditions and the following disclaimer in the  *
 *    documentation and/or other materials provided with the distribution. *
 * 3. Neither the name of Punch Telematix or of /k/ Embedded Java Solutions*
 *    nor the names of other contributors may be used to endorse or promote*
 *    products derived from this software without specific prior written   *
 *    permission.                                                          *
 *                                                                         *
 * THIS SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED          *
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF    *
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.    *
 * IN NO EVENT SHALL PUNCH TELEMATIX, /K/ EMBEDDED JAVA SOLUTIONS OR OTHER *
 * CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,   *
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,     *
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR      *
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF  *
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING    *
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS      *
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.            *
 **************************************************************************/

package java.util;

import java.io.Serializable;

abstract public class TimeZone implements Serializable, Cloneable {

    private static final long serialVersionUID = 3581463369166924961L;

    public static final int SHORT = 0;
    public static final int LONG = 1;

    /**
     * The always-available GMT time zone. Package-visible for the benefit of
     * GregorianCalendar
     */
    static TimeZone GMT = new SimpleTimeZone(0, "GMT");

    private static TimeZone defaultTZ = GMT;
    private String ID; //name specified by serialization ...

    /**
     ** Set the default TimeZone. If tz is null then we try to get
     * "jainja.resource.TimeZoneResourceBundle", and if that fails we default to
     * GMT.
     ** 
     * @param tz
     *            The new default TimeZone, or null to reset the default.
     */
    public static synchronized void setDefault(TimeZone tz) {
        defaultTZ = tz;
    }

    /**
     ** Set this TimeZone's ID.
     ** 
     * @param newID
     *            The new ID.
     */
    public void setID(String newID) {
        if (newID == null) {
            throw new NullPointerException();
        }
        ID = newID;
    }

    public String getID() {
        return ID;
    }

    public boolean hasSameRules(TimeZone tz) {
        return ((this.getRawOffset() == tz.getRawOffset()) && (this.useDaylightTime() == tz.useDaylightTime()));
    }

    public String toString() {
        return super.toString() + "ID=" + ID;
    }

    public final String getDisplayName() {
        return getDisplayName(false, LONG, Locale.getDefault());
    }

    public final String getDisplayName(Locale loc) {
        return getDisplayName(false, LONG, loc);
    }

    public final String getDisplayName(boolean daylight, int style) {
        return getDisplayName(daylight, style, Locale.getDefault());
    }

    public String getDisplayName(boolean daylight, int style, Locale loc) {
        // the Locale is used to load the correct ResourceBundle ...
        // ID is the key within the ResourceBundle which contains arrays of Strings
        // daylight, style will be used to determine which String is needed ...
        // 0 ==> short name, 1 ==> long name, 2 ==> short name dst, 3 ==> long name dst
        String[] sa = null;
        int i = style + (daylight ? 2 : 0);
        String s = null;
        // make a default value
        if (s == null) {
            StringBuffer buf = new StringBuffer("GMT");
            int offset = getRawOffset();
            if (daylight) {
                offset += 3600000;
            }
            if (offset >= 0) {
                buf.append('+');
            } else {
                buf.append('-');
                offset *= -1;
            }
            int h = offset / 3600000;
            buf.append((char) ('0' + h / 10));
            buf.append((char) ('0' + h % 10));
            buf.append(':');
            h = (offset % 3600000) / 60000;
            buf.append((char) ('0' + h / 10));
            buf.append((char) ('0' + h % 10));
            s = new String(buf);
        }
        return s;
    }

    public int getDSTSavings() {
        return useDaylightTime() ? 3600000 : 0;
    }

    public int getOffset(long date) {
        return (this.inDaylightTime(new Date(date)) ? getDSTSavings() : 0) + getRawOffset();
    }

    public Object clone() {
        try {
            return super.clone();
        } catch (CloneNotSupportedException cnse) {
            return null;
        }
    }

    //Declaration of abstract Methods ...

    public abstract int getOffset(int era, int year, int month, int day, int dayOffWeek, int milliseconds);

    public abstract int getRawOffset();

    public abstract void setRawOffset(int offsetMillis);

    public abstract boolean inDaylightTime(Date date);

    public abstract boolean useDaylightTime();

    //Implementation of static Methods ...

    public static synchronized TimeZone getDefault() {
        return defaultTZ;
    }

    public static synchronized TimeZone getTimeZone(String rID) {
        TimeZone result = new SimpleTimeZone(0, "GMT");
        return result;
    }

    public static synchronized String[] getAvailableIDs() {
        return new String[0];
    }

    public static synchronized String[] getAvailableIDs(int rawOffset) {
        return new String[0];
    }

}
