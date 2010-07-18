/* Singleton to obtain available translation modes from Apertium.
 *
 * Copyright (C) 2010 Free Software Foundation, Inc.
 *
 * Written by:  Niels Grewe
 * Created:  July 2010
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02111
 * USA.
 */
#import <Foundation/NSObject.h>

@class NSArray, NSMutableDictionary, NSString;

@interface ApertiumInfo: NSObject
{
  NSMutableDictionary *languagePairs;
}

+ (ApertiumInfo*)sharedApertiumInfo;

- (NSArray*)sourceLanguages;

- (NSArray*)destinationLanguagesForSourceLanguage: (NSString*)langKey;

- (BOOL) canTranslate: (NSString*)src
                 into: (NSString*)dst;

- (NSString*)localizedLanguageNameForLangKey: (NSString*)langKey;
@end
