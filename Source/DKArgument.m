/** Implementation of DKArgument class for boxing and unboxing D-Bus types.
   Copyright (C) 2010 Free Software Foundation, Inc.

   Written by:  Niels Grewe <niels.grewe@halbordnung.de>
   Created: June 2010

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   <title>DKArgument class reference</title>
   */

#import <Foundation/NSArray.h>
#import <Foundation/NSDebug.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSException.h>
#import <Foundation/NSEnumerator.h>
#import <Foundation/NSInvocation.h>
#import <Foundation/NSMethodSignature.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSString.h>
#import <Foundation/NSValue.h>
#import <GNUstepBase/NSDebug+GNUstepBase.h>
#import "DBusKit/DKProxy.h"
#import "DKEndpoint.h"
#import "DKArgument.h"

#include <dbus/dbus.h>

NSString *DKArgumentDirectionIn = @"in";
NSString *DKArgumentDirectionOut = @"out";



static Class
DKObjCClassForDBusType(int type)
{
  switch (type)
  {
    case DBUS_TYPE_BYTE:
    case DBUS_TYPE_BOOLEAN:
    case DBUS_TYPE_INT16:
    case DBUS_TYPE_UINT16:
    case DBUS_TYPE_INT32:
    case DBUS_TYPE_UINT32:
    case DBUS_TYPE_INT64:
    case DBUS_TYPE_UINT64:
    case DBUS_TYPE_DOUBLE:
      return [NSNumber class];
    case DBUS_TYPE_STRING:
      return [NSString class];
    case DBUS_TYPE_OBJECT_PATH:
      return [DKProxy class];
    case DBUS_TYPE_SIGNATURE:
      return [DKArgument class];
    // Some DBUS_TYPE_ARRAYs will actually be dictionaries if they contain
    // DBUS_TYPE_DICT_ENTRies.
    case DBUS_TYPE_ARRAY:
    case DBUS_TYPE_STRUCT:
      return [NSArray class];
    // The following types have no explicit representation, they will either not
    // be handled at all, or their boxing is determined by the container resp.
    // the contained type.
    case DBUS_TYPE_INVALID:
    case DBUS_TYPE_VARIANT:
    case DBUS_TYPE_DICT_ENTRY:
    default:
      break;
  }
  return Nil;
}

static char*
DKUnboxedObjCTypeForDBusType(int type)
{
  switch (type)
  {
    case DBUS_TYPE_BYTE:
      return @encode(char);
    case DBUS_TYPE_BOOLEAN:
      return @encode(BOOL);
    case DBUS_TYPE_INT16:
      return @encode(int16_t);
    case DBUS_TYPE_UINT16:
      return @encode(uint16_t);
    case DBUS_TYPE_INT32:
      return @encode(int32_t);
    case DBUS_TYPE_UINT32:
      return @encode(uint32_t);
    case DBUS_TYPE_INT64:
      return @encode(int64_t);
    case DBUS_TYPE_UINT64:
      return @encode(uint64_t);
    case DBUS_TYPE_DOUBLE:
      return @encode(double);
    case DBUS_TYPE_STRING:
      return @encode(char*);
    // We always box the following types:
    case DBUS_TYPE_OBJECT_PATH:
    case DBUS_TYPE_ARRAY:
    case DBUS_TYPE_STRUCT:
    case DBUS_TYPE_VARIANT:
      return @encode(id);
    // And because we do, the following types will never appear in a signature:
    case DBUS_TYPE_INVALID:
    case DBUS_TYPE_SIGNATURE:
    case DBUS_TYPE_DICT_ENTRY:
    default:
      return '\0';
  }
  return '\0';
}
static size_t
DKUnboxedObjCTypeSizeForDBusType(int type)
{
  switch (type)
  {
    case DBUS_TYPE_BYTE:
      return sizeof(char);
    case DBUS_TYPE_BOOLEAN:
      return sizeof(BOOL);
    case DBUS_TYPE_INT16:
      return sizeof(int16_t);
    case DBUS_TYPE_UINT16:
      return sizeof(uint16_t);
    case DBUS_TYPE_INT32:
      return sizeof(int32_t);
    case DBUS_TYPE_UINT32:
      return sizeof(uint32_t);
    case DBUS_TYPE_INT64:
      return sizeof(int64_t);
    case DBUS_TYPE_UINT64:
      return sizeof(uint64_t);
    case DBUS_TYPE_DOUBLE:
      return sizeof(double);
    case DBUS_TYPE_STRING:
      return sizeof(char*);
    // We always box the following types:
    case DBUS_TYPE_OBJECT_PATH:
    case DBUS_TYPE_ARRAY:
    case DBUS_TYPE_STRUCT:
    case DBUS_TYPE_VARIANT:
      return sizeof(id);
    // And because we do, the following types will never appear in a signature:
    case DBUS_TYPE_INVALID:
    case DBUS_TYPE_SIGNATURE:
    case DBUS_TYPE_DICT_ENTRY:
    default:
      return 0;
  }
  return 0;
}

/*
 * Expose DKProxy privates that we need to access.
 */
@interface DKProxy (Private)
- (NSString*)_path;
- (NSString*)_service;
- (DKEndpoint*)_endpoint;
@end


/*
 * Private Container argument subclasses:
 */

@interface DKStructTypeArgument: DKContainerTypeArgument
@end

@interface DKArrayTypeArgument: DKContainerTypeArgument
- (BOOL) isDictionary;
- (void) setIsDictionary: (BOOL)isDict;
@end

/* D-Bus marshalls dictionaries as arrays of key/value pairs. */
@interface DKDictionaryTypeArgument: DKArrayTypeArgument
@end

@interface DKVariantTypeArgument: DKContainerTypeArgument
@end

/* It seems sensible to regard dict entries as struct types. */
@interface DKDictEntryTypeArgument: DKStructTypeArgument
- (DKArgument*) keyArgument;
- (DKArgument*) valueArgument;
- (void) unmarshallFromIterator: (DBusMessageIter*)iter
                          value: (id*)value
                            key: (id*)key;
- (void) marshallObject: (id)object
                 forKey: (id)key
           intoIterator: (DBusMessageIter*)iter;
@end

/**
 *  DKArgument encapsulates D-Bus argument information
 */
@implementation DKArgument
- (id) initWithIterator: (DBusSignatureIter*)iterator
                   name: (NSString*)_name
                 parent: (id)_parent
{
  if (nil == (self = [super initWithName: _name
                                  parent: _parent]))
  {
    return nil;
  }

  DBusType = dbus_signature_iter_get_current_type(iterator);

  if ((dbus_type_is_container(DBusType))
    && (![self isKindOfClass: [DKContainerTypeArgument class]]))
  {
    NSDebugMLog(@"Incorrectly initalized a non-container argument with a container type, reinitializing as container type.");
    [self release];
    return [[DKContainerTypeArgument alloc] initWithIterator: iterator
                                                        name: _name
                                                      parent: _parent];
  }
  objCEquivalent = DKObjCClassForDBusType(DBusType);
  return self;
}

- (id)initWithDBusSignature: (const char*)DBusTypeString
                       name: (NSString*)_name
                     parent: (id)_parent
{
  DBusSignatureIter myIter;
  if (!dbus_signature_validate_single(DBusTypeString, NULL))
  {
    NSWarnMLog(@"Not a single D-Bus type signature ('%s'), ignoring argument", DBusTypeString);
    [self release];
    return nil;
  }

  dbus_signature_iter_init(&myIter, DBusTypeString);
  return [self initWithIterator: &myIter
                           name: _name
                         parent: _parent];
}



- (void)setObjCEquivalent: (Class)class
{
  objCEquivalent = class;
}

- (Class) objCEquivalent
{
  return objCEquivalent;
}

- (int) DBusType
{
  return DBusType;
}

- (NSString*) DBusTypeSignature
{
  return [NSString stringWithCharacters: (unichar*)&DBusType length: 1];

}

- (char*) unboxedObjCTypeChar
{
  return DKUnboxedObjCTypeForDBusType(DBusType);
}

- (size_t)unboxedObjCTypeSize
{
  return DKUnboxedObjCTypeSizeForDBusType(DBusType);
}
- (BOOL) isContainerType
{
  return NO;
}

/**
 * This method returns the root ancestor in the method/arugment tree if it is a
 * proxy. Otherwise it returns nil. This information is needed for boxing and
 * unboxing values that depend on the object to which a method is associated
 * (i.e. object paths).
 */
- (DKProxy*)proxyParent
{
  id ancestor = [self parent];
  do
  {
    if ([ancestor isKindOfClass: [DKProxy class]])
    {
      return ancestor;
    }
    else if (![ancestor respondsToSelector: @selector(parent)])
    {
      return nil;
    }
  } while (nil != (ancestor = [ancestor parent]));

  return nil;
}


- (BOOL) unboxValue: (id)value
         intoBuffer: (long long*)buffer
{
  switch (DBusType)
  {
    case DBUS_TYPE_BYTE:
       if ([value respondsToSelector: @selector(unsignedCharValue)])
       {
	 *buffer = [value unsignedCharValue];
         return YES;
       }
       break;
    case DBUS_TYPE_BOOLEAN:
       if ([value respondsToSelector: @selector(boolValue)])
       {
	 *buffer = [value boolValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_INT16:
       if ([value respondsToSelector: @selector(shortValue)])
       {
	 *buffer = [value shortValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_INT32:
       if ([value respondsToSelector: @selector(intValue)])
       {
	 *buffer = [value intValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_UINT16:
       if ([value respondsToSelector: @selector(unsignedShortValue)])
       {
	 *buffer = [value unsignedShortValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_UINT32:
       if ([value respondsToSelector: @selector(unsignedIntValue)])
       {
	 *buffer = [value unsignedIntValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_INT64:
       if ([value respondsToSelector: @selector(longLongValue)])
       {
	 *buffer = [value longLongValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_UINT64:
       if ([value respondsToSelector: @selector(unsignedLongLongValue)])
       {
	 *buffer = [value unsignedLongLongValue];
	 return YES;
       }
       break;
    case DBUS_TYPE_DOUBLE:
       if ([value respondsToSelector: @selector(doubleValue)])
       {
	 union fpAndLLRep
	 {
           long long buf;
	   double val;
	 } rep;
	 rep.val = [value doubleValue];
	 *buffer = rep.buf;
	 return YES;
       }
       break;
    case DBUS_TYPE_STRING:
       if ([value respondsToSelector: @selector(UTF8String)])
       {
	 *buffer = (uintptr_t)[value UTF8String];
	 return YES;
       }
       break;
    case DBUS_TYPE_OBJECT_PATH:
    if ([value isKindOfClass: [DKProxy class]])
    {
      /*
       * We need to make sure that the paths are from the same proxy, because
       * that is the widest scope in which they are valid.
       */
      if ([[self proxyParent] hasSameScopeAs: value])
      {
        *buffer = (uintptr_t)[[value _path] UTF8String];
        return YES;
      }
    }
    break;
    case DBUS_TYPE_SIGNATURE:
      if ([value respondsToSelector: @selector(DBusTypeSignature)])
      {
	*buffer = (uintptr_t)[[value DBusTypeSignature] UTF8String];
	return YES;
      }
      break;
    default:
      break;
  }
  return NO;
}

- (id) boxedValueForValueAt: (void*)buffer
{
  switch (DBusType)
  {
    case DBUS_TYPE_BYTE:
      return [objCEquivalent numberWithUnsignedChar: *(unsigned char*)buffer];
    case DBUS_TYPE_BOOLEAN:
      return [objCEquivalent numberWithBool: *(BOOL*)buffer];
    case DBUS_TYPE_INT16:
      return [objCEquivalent numberWithShort: *(int16_t*)buffer];
    case DBUS_TYPE_UINT16:
      return [objCEquivalent numberWithUnsignedShort: *(uint16_t*)buffer];
    case DBUS_TYPE_INT32:
      return [objCEquivalent numberWithInt: *(int32_t*)buffer];
    case DBUS_TYPE_UINT32:
      return [objCEquivalent numberWithUnsignedInt: *(uint32_t*)buffer];
    case DBUS_TYPE_INT64:
      return [objCEquivalent numberWithLongLong: *(int64_t*)buffer];
    case DBUS_TYPE_UINT64:
      return [objCEquivalent numberWithUnsignedLongLong: *(uint64_t*)buffer];
    case DBUS_TYPE_DOUBLE:
      return [objCEquivalent numberWithDouble: *(double*)buffer];
    case DBUS_TYPE_STRING:
      return [objCEquivalent stringWithUTF8String: *(char**)buffer];
    case DBUS_TYPE_OBJECT_PATH:
    {
      /*
       * To handle object-paths, we follow the argument/method tree back to the
       * proxy where it was created and create a new proxy with the proper
       * settings.
       */
      DKProxy *ancestor = [self proxyParent];
      NSString *service = [ancestor _service];
      DKEndpoint *endpoint = [ancestor _endpoint];
      NSString *path = [[NSString alloc] initWithUTF8String: *(char**)buffer];
      DKProxy *newProxy = [objCEquivalent proxyWithEndpoint: endpoint
	                                         andService: service
	                                            andPath: path];
      [path release];
      return newProxy;
    }
    case DBUS_TYPE_SIGNATURE:
      return [[[objCEquivalent alloc] initWithDBusSignature: *(char**)buffer
                                                       name: nil
                                                     parent: nil] autorelease];
    default:
      return nil;
  }
  return nil;
}


- (void) unmarshallFromIterator: (DBusMessageIter*)iter
                 intoInvocation: (NSInvocation*)inv
		        atIndex: (NSInteger)index
			 boxing: (BOOL)doBox
{
  // All basic types are guaranteed to fit into 64bit.
  uint64_t buffer = 0;

  // Type checking:
  const char *invType;
  const char *expectedType;

  // Check that the method contains the expected type.
  NSAssert((dbus_message_iter_get_arg_type(iter) == DBusType),
    @"Type mismatch between D-Bus message and introspection data.");

  if (doBox)
  {
    expectedType = @encode(id);
  }
  else
  {
    expectedType = [self unboxedObjCTypeChar];
  }

  if (index == -1)
  {
    invType = [[inv methodSignature] methodReturnType];
  }
  else
  {
    invType = [[inv methodSignature] getArgumentTypeAtIndex: index];
  }

  // Check whether the invocation has a matching call frame:
  NSAssert((0 == strcmp(invType, expectedType)),
    @"Type mismatch between introspection data and invocation.");

  dbus_message_iter_get_basic(iter, (void*)&buffer);

  if (doBox)
  {
    id value = [self boxedValueForValueAt: (void*)&buffer];
    if (index == -1)
    {
      [inv setReturnValue: &value];
    }
    else
    {
      [inv setArgument: &value
               atIndex: index];
    }
  }
  else
  {
    if (index == -1)
    {
      [inv setReturnValue: (void*)&buffer];
    }
    else
    {
      [inv setArgument: (void*)&buffer
               atIndex: index];
    }
  }
}

-(id) unmarshalledObjectFromIterator: (DBusMessageIter*)iter
{
  // All basic types are guaranteed to fit into 64bit.
  uint64_t buffer = 0;

  // Check that the method contains the expected type.
  NSAssert((dbus_message_iter_get_arg_type(iter) == DBusType),
    @"Type mismatch between D-Bus message and introspection data.");

  dbus_message_iter_get_basic(iter, (void*)&buffer);

  return [self boxedValueForValueAt: (void*)&buffer];
}

- (void) marshallArgumentAtIndex: (NSInteger)index
                  fromInvocation: (NSInvocation*)inv
                    intoIterator: (DBusMessageIter*)iter
                          boxing: (BOOL)doBox
{
  uint64_t buffer = 0;
  const char* invType;
  const char* expectedType;

  if (doBox)
  {
    expectedType = @encode(id);
  }
  else
  {
    expectedType = [self unboxedObjCTypeChar];
  }

  if (-1 == index)
  {
    invType = [[inv methodSignature] methodReturnType];
  }
  else
  {
    invType = [[inv methodSignature] getArgumentTypeAtIndex: index];
  }

  NSAssert((0 == strcmp(expectedType, invType)),
    @"Type mismatch between introspection data and invocation.");

  if (doBox)
  {
    id value = nil;

    if (-1 == index)
    {
      [inv getReturnValue: &value];
    }
    else
    {
      [inv getArgument: &value
               atIndex: index];
    }

    NSAssert1([self unboxValue: value intoBuffer: (long long int*)(void*)&buffer],
      @"Could not unbox object '%@' into D-Bus format",
      value);
  }
  else
  {
    if (-1 == index)
    {
      [inv getReturnValue: (void*)&buffer];
    }
    else
    {
      [inv getArgument: (void*)&buffer
               atIndex: index];
    }
  }

  NSAssert(dbus_message_iter_append_basic(iter, DBusType, (void*)&buffer),
    @"Out of memory when marshalling D-Bus data.");
}

- (void) marshallObject: (id)object
           intoIterator: (DBusMessageIter*)iter
{
  long long int buffer = 0;
  NSAssert1([self unboxValue: object intoBuffer: &buffer],
    @"Could not unbox object '%@' into D-Bus format",
    object);
  NSAssert(dbus_message_iter_append_basic(iter, DBusType, (void*)&buffer),
    @"Out of memory when marshalling D-Bus data.");
}

@end


@implementation DKContainerTypeArgument

- (id)initWithIterator: (DBusSignatureIter*)iterator
                  name: (NSString*)_name
                parent: (id)_parent
{
  DBusSignatureIter subIterator;
  if (nil == (self = [super initWithIterator: iterator
                                        name: _name
                                      parent: _parent]))
  {
    return nil;
  }

  if (!dbus_type_is_container(DBusType))
  {
    NSWarnMLog(@"Incorrectly initialized container type D-Bus argument ('%@' is not a container type).",
      [NSString stringWithCharacters: (unichar*)&DBusType length: 1]);
      [self release];
      return nil;
  }

  children = [[NSMutableArray alloc] init];

  switch (DBusType)
  {
    case DBUS_TYPE_VARIANT:
     /*
      * A shortcut is needed for variant types. libdbus classifies them as
      * containers, but it is clearly wrong about that: They have no children
      * and dbus will fail and crash if it tries to loop over their non-existent
      * sub-arguments. Hence we return after setting the subclass.
      */
      isa = [DKVariantTypeArgument class];
      return self;
    case DBUS_TYPE_ARRAY:
      isa = [DKArrayTypeArgument class];
      break;
    case DBUS_TYPE_STRUCT:
      isa = [DKStructTypeArgument class];
      break;
    case DBUS_TYPE_DICT_ENTRY:
      isa = [DKDictEntryTypeArgument class];
      break;
    default:
      NSWarnMLog(@"Cannot handle unkown container type.");
      [self release];
      return nil;
  }

  /*
   * Create an iterator for the immediate subarguments of this argument and loop
   * over it until we have all the constituent types.
   */
  dbus_signature_iter_recurse(iterator, &subIterator);
  do
  {
    Class childClass = Nil;
    DKArgument *subArgument = nil;
    int subType = dbus_signature_iter_get_current_type(&subIterator);

    if (dbus_type_is_container(subType))
    {
       childClass = [DKContainerTypeArgument class];
    }
    else
    {
      childClass = [DKArgument class];
    }

    subArgument = [[childClass alloc] initWithIterator: &subIterator
                                                  name: _name
                                                parent: self];
    if (subArgument)
    {
      [children addObject: subArgument];
      [subArgument release];
    }
  } while (dbus_signature_iter_next(&subIterator));

  /* Be smart: If we are ourselves of DBUS_TYPE_DICT_ENTRY, then a
   * DBUS_TYPE_ARRAY argument above us is actually a dictionary, so we set the
   * type accordingly.
   */
  if (DBUS_TYPE_DICT_ENTRY == DBusType)
  {
    if ([parent isKindOfClass: [DKArrayTypeArgument class]])
    {
      if (DBUS_TYPE_ARRAY == [(id)parent DBusType])
      {
	[(id)parent setIsDictionary: YES];
      }
    }
  }
  return self;
}

/*
 * All container types are boxed.
 */
- (char*) unboxedObjCTypeChar
{
  return @encode(id);
}

- (size_t) unboxedObjCTypeSize
{
  return sizeof(id);
}

- (id) boxedValueForValueAt: (void*)buffer
{
  // It is a bad idea to try this on a container type.
  [self shouldNotImplement: _cmd];
  return nil;
}

- (NSString*) DBusTypeSignature
{
  NSMutableString *sig = [[NSMutableString alloc] init];
  NSString *ret = nil;
  // [[children fold] stringByAppendingString: @""]
  NSEnumerator *enumerator = [children objectEnumerator];
  DKArgument *subArg = nil;
  while (nil != (subArg = [enumerator nextObject]))
  {
    [sig appendString: [subArg DBusTypeSignature]];
  }

  switch (DBusType)
  {
    case DBUS_TYPE_VARIANT:
      [sig insertString: [NSString stringWithUTF8String: DBUS_TYPE_VARIANT_AS_STRING]
                atIndex: 0];
      break;
    case DBUS_TYPE_ARRAY:
      [sig insertString: [NSString stringWithUTF8String: DBUS_TYPE_ARRAY_AS_STRING]
                atIndex: 0];
      break;
    case DBUS_TYPE_STRUCT:
      [sig insertString: [NSString stringWithUTF8String: DBUS_STRUCT_BEGIN_CHAR_AS_STRING]
                                                atIndex: 0];
      [sig appendString: [NSString stringWithUTF8String: DBUS_STRUCT_END_CHAR_AS_STRING]];
      break;
    case DBUS_TYPE_DICT_ENTRY:
      [sig insertString: [NSString stringWithUTF8String: DBUS_DICT_ENTRY_BEGIN_CHAR_AS_STRING]
                                                atIndex: 0];
      [sig appendString: [NSString stringWithUTF8String: DBUS_DICT_ENTRY_END_CHAR_AS_STRING]];
      break;
    default:
      NSAssert(NO, @"Invalid D-Bus type when generating container type signature");
      break;
  }
  ret = [NSString stringWithString: sig];
  [sig release];
  return ret;
}

- (BOOL) isContainerType
{
  return YES;
}

- (NSArray*) children
{
  return children;
}

/*
 * Since we always box container types, we can simply set the argument/return
 * values to the object produced by unmarshalling.
 */
- (void) unmarshallFromIterator: (DBusMessageIter*)iter
                 intoInvocation: (NSInvocation*)inv
		        atIndex: (NSInteger)index
			 boxing: (BOOL)doBox
{
  id value = [self unmarshalledObjectFromIterator: iter];

  if (-1 == index)
  {
    NSAssert((@encode(id) == [[inv methodSignature] methodReturnType]),
      @"Type mismatch between introspection data and invocation.");
    [inv setReturnValue: &value];
  }
  else
  {
    NSAssert((@encode(id) == [[inv methodSignature] getArgumentTypeAtIndex: index]),
      @"Type mismatch between introspection data and invocation.");
    [inv setArgument: &value
             atIndex: index];
  }
}

-(id) unmarshalledObjectFromIterator: (DBusMessageIter*)iter
{
  [self subclassResponsibility: _cmd];
  return nil;
}

- (void) marshallArgumentAtIndex: (NSInteger)index
                  fromInvocation: (NSInvocation*)inv
                    intoIterator: (DBusMessageIter*)iter
                          boxing: (BOOL)doBox
{
  id value = nil;

  if (-1 == index)
  {
    NSAssert((@encode(id) == [[inv methodSignature] methodReturnType]),
      @"Type mismatch between introspection data and invocation.");
    [inv getReturnValue: &value];
  }
  else
  {
    NSAssert((@encode(id) == [[inv methodSignature] getArgumentTypeAtIndex: index]),
      @"Type mismatch between introspection data and invocation.");
    [inv getArgument: &value
             atIndex: index];
  }
  [self marshallObject: value
          intoIterator: iter];
}

- (void) marshallObject: (id)object
           intoIterator: (DBusMessageIter*)iter
{
  [self subclassResponsibility: _cmd];
}

- (void) dealloc
{
  [children release];
  [super dealloc];
}
@end;

@implementation DKArrayTypeArgument
- (id)initWithIterator: (DBusSignatureIter*)iterator
                  name: (NSString*)_name
                parent: (id)_parent
{
  NSUInteger childCount = 0;
  if (nil == (self = [super initWithIterator: iterator
                                        name: _name
                                      parent: _parent]))
  {
    return nil;
  }

  childCount = [children count];

  // Arrays can only have a single type:
  if (childCount != 1)
  {
    NSWarnMLog(@"Invalid number of children (%lu) for D-Bus array argument",
      childCount);
    [self release];
    return nil;
  }

  return self;
}

- (BOOL) isDictionary
{
  return [self isKindOfClass: [DKDictionaryTypeArgument class]];
}

- (void) setIsDictionary: (BOOL)isDict
{
  if (isDict)
  {
    isa = [DKDictionaryTypeArgument class];
    [self setObjCEquivalent: [NSDictionary class]];
  }
  else
  {
    // Not sure why somebody would want to do that
    isa = [DKArrayTypeArgument class];
    [self setObjCEquivalent: [NSArray class]];
  }
}

- (DKArgument*)elementTypeArgument
{
  return [children objectAtIndex: 0];
}


- (void) assertSaneIterator: (DBusMessageIter*)iter
{
  int childType = DBUS_TYPE_INVALID;
  // Make sure we are deserializing an array:
  NSAssert((DBUS_TYPE_ARRAY == dbus_message_iter_get_arg_type(iter)),
    @"Non array type when unmarshalling array from message.");
  childType = dbus_message_iter_get_element_type(iter);

  // Make sure we have the expected element type.
  NSAssert((childType == [[self elementTypeArgument] DBusType]),
    @"Type mismatch between D-Bus message and introspection data.");
}

-(id) unmarshalledObjectFromIterator: (DBusMessageIter*)iter
{
  DKArgument *theChild = [self elementTypeArgument];
  DBusMessageIter subIter;
  NSMutableArray *theArray = [NSMutableArray new];
  NSArray *returnArray = nil;
  NSNull *theNull = [NSNull null];

  [self assertSaneIterator: iter];

  dbus_message_iter_recurse(iter, &subIter);
  do
  {
    id obj = [theChild unmarshalledObjectFromIterator: &subIter];
    if (nil == obj)
    {
      obj = theNull;
    }
    [theArray addObject: obj];
  } while (dbus_message_iter_next(&subIter));

  returnArray = [NSArray arrayWithArray: theArray];
  [theArray release];
  return returnArray;
}

- (void) marshallObject: (id)object
           intoIterator: (DBusMessageIter*)iter
{
  DBusMessageIter subIter;
  DKArgument *theChild = [self elementTypeArgument];
  NSEnumerator *elementEnum = nil;
  id element = nil;

  NSAssert1([object respondsToSelector: @selector(objectEnumerator)],
    @"Cannot enumerate contents of %@ when creating D-Bus array.",
    object);

  NSAssert(dbus_message_iter_open_container(iter,
    DBUS_TYPE_ARRAY,
    [[theChild DBusTypeSignature] UTF8String],
    &subIter),
    @"Out of memory when creating D-Bus iterator for container.");

  elementEnum = [object objectEnumerator];
  NS_DURING
  {
    while (nil != (element = [elementEnum nextObject]))
    {
      [theChild marshallObject: element
                  intoIterator: &subIter];

    }
  }
  NS_HANDLER
  {
    // We are already screwed and don't care whether
    // dbus_message_iter_close_container() returns OOM.
    dbus_message_iter_close_container(iter, &subIter);
    [localException raise];
  }
  NS_ENDHANDLER

  NSAssert(dbus_message_iter_close_container(iter, &subIter),
    @"Out of memory when closing D-Bus container.");
}
@end

@implementation DKDictionaryTypeArgument
/*
 * NOTE: Most of the time, this initializer will not be used, because we only
 * know ex-post whether something is a dictionary (by virtue of having elements
 * of DBUS_TYPE_DICT_ENTRY).
 */
- (id)initWithIterator: (DBusSignatureIter*)iterator
                  name: (NSString*)_name
                parent: (id)_parent
{
  if (nil == (self = [super initWithIterator: iterator
                                        name: _name
                                      parent: _parent]))
  {
    return nil;
  }

  if (![[self elementTypeArgument] isKindOfClass: [DKDictEntryTypeArgument class]])
  {
    NSWarnMLog(@"Invalid dictionary type argument (does not contan a dict entry).");
    [self release];
    return nil;
  }
  return self;
}


- (void) assertSaneIterator: (DBusMessageIter*)iter
{
  [super assertSaneIterator: iter];
  NSAssert((DBUS_TYPE_DICT_ENTRY == dbus_message_iter_get_element_type(iter)),
    @"Non dict-entry type in iterator when unmarshalling a dictionary.");
}

-(id) unmarshalledObjectFromIterator: (DBusMessageIter*)iter
{
  DKDictEntryTypeArgument *theChild = (DKDictEntryTypeArgument*)[self elementTypeArgument];
  DBusMessageIter subIter;
  NSMutableDictionary *theDictionary = [NSMutableDictionary new];
  NSDictionary *returnDictionary = nil;
  NSNull *theNull = [NSNull null];

  [self assertSaneIterator: iter];

  // We loop over the dict entries:
  dbus_message_iter_recurse(iter, &subIter);
  do
  {
    id value = nil;
    id key = nil;

    [theChild unmarshallFromIterator: &subIter
                               value: &value
                                 key: &key];
    if (key == nil)
    {
      key = theNull;
    }
    if (value == nil)
    {
      value = theNull;
    }

    if (nil == [theDictionary objectForKey: key])
    {
      /*
       * From the D-Bus specification:
       * "A message is considered corrupt if the same key occurs twice in the
       * same array of DICT_ENTRY. However, for performance reasons
       * implementations are not required to reject dicts with duplicate keys."
       * We choose to just ignore duplicate keys:
       */
      [theDictionary setObject: value
                        forKey: key];
    }
    else
    {
      NSWarnMLog(@"Ignoring duplicate key (%@) in D-Bus dictionary.", key);
    }

  } while (dbus_message_iter_next(&subIter));

  returnDictionary = [NSDictionary dictionaryWithDictionary: theDictionary];
  [theDictionary release];
  return returnDictionary;
}

- (void) marshallObject: (id)object
           intoIterator: (DBusMessageIter*)iter
{
  NSArray *keys = nil;
  NSEnumerator *keyEnum = nil;
  DKDictEntryTypeArgument *pairArgument = (DKDictEntryTypeArgument*)[self elementTypeArgument];
  id element = nil;

  DBusMessageIter subIter;

  NSAssert1(([object respondsToSelector: @selector(allKeys)]
    && [object respondsToSelector: @selector(objectForKey:)]),
    @"Cannot marshall non key/value dictionary '%@' to D-Bus iterator.",
    object);

  NSAssert(dbus_message_iter_open_container(iter,
    DBUS_TYPE_ARRAY,
    [[pairArgument DBusTypeSignature] UTF8String],
    &subIter),
    @"Out of memory when creating D-Bus iterator for container.");
  keys = [object allKeys];
  keyEnum = [keys objectEnumerator];

  NS_DURING
  {
    while (nil != (element = [keyEnum nextObject]))
    {
      [pairArgument marshallObject: [object objectForKey: element]
                            forKey: element
		      intoIterator: &subIter];
    }
  }
  NS_HANDLER
  {
    // Something already went wrong and we don't care for a potential OOM error
    // from dbus_message_iter_close_container();
    dbus_message_iter_close_container(iter, &subIter);
    [localException raise];
  }
  NS_ENDHANDLER

  NSAssert(dbus_message_iter_close_container(iter, &subIter),
    @"Out of memory when closing D-Bus container.");
}
@end

@implementation DKStructTypeArgument
@end

@implementation DKVariantTypeArgument
@end

@implementation DKDictEntryTypeArgument
- (id)initWithIterator: (DBusSignatureIter*)iterator
                  name: (NSString*)_name
                parent: (id)_parent
{
  NSUInteger childCount = 0;
  if (nil == (self = [super initWithIterator: iterator
                                        name: _name
                                      parent: _parent]))
  {
    return nil;
  }

  childCount = [children count];

  // Dictionaries have exactly two types:
  if (childCount != 2)
  {
    NSWarnMLog(@"Invalid number of children (%lu) for D-Bus dict entry argument. Ignoring argument.",
      childCount);
    [self release];
    return nil;
  }
  else if (![[children objectAtIndex: 0] isContainerType])
  {
    NSWarnMLog(@"Invalid (complex) type as dict entry key. Ignoring argument.");
    [self release];
    return nil;
  }

  return self;
}

- (DKArgument*)keyArgument
{
  return [children objectAtIndex: 0];
}

- (DKArgument*)valueArgument
{
  return [children objectAtIndex: 1];
}

- (void) unmarshallFromIterator: (DBusMessageIter*)iter
                          value: (id*)value
                            key: (id*)key
{
  DBusMessageIter subIter;
  NSAssert((DBUS_TYPE_DICT_ENTRY == dbus_message_iter_get_arg_type(iter)),
    @"Type mismatch between introspection data and D-Bus message.");

  dbus_message_iter_recurse(iter, &subIter);

  *key = [[self keyArgument]  unmarshalledObjectFromIterator: &subIter];

  if (dbus_message_iter_next(&subIter))
  {
    *value = [[self valueArgument] unmarshalledObjectFromIterator: &subIter];
  }
  else
  {
    *value = nil;
  }
  return;
}
- (void) marshallObject: (id)object
                 forKey: (id)key
           intoIterator: (DBusMessageIter*)iter
{
  DBusMessageIter subIter;
  NSAssert(dbus_message_iter_open_container(iter,
    DBUS_TYPE_DICT_ENTRY,
    NULL, // contained_signature set to NULL as per libdbus documentation
    &subIter),
    @"Out of memory when opening D-Bus container.");
  NS_DURING
  {
    [[self keyArgument] marshallObject: key
                          intoIterator: &subIter];
    [[self valueArgument] marshallObject: object
                            intoIterator: &subIter];
  }
  NS_HANDLER
  {
    // Again, we don't care for OOM here because we already failed.
    dbus_message_iter_close_container(iter, &subIter);
    [localException raise];
  }
  NS_ENDHANDLER

  NSAssert(dbus_message_iter_close_container(iter, &subIter),
    @"Out of memory when closing D-Bus container.");
}
@end
